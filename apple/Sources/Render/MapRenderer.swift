//  MapRenderer.swift
//  Metal 2D map: quadtree LOD over CPU-rasterised tiles, plus marker symbology.

import Foundation
import Metal
import MetalKit
import simd
import Worldgen

let WORLD_EXTENT: Float = 10500.0
let WORLD_SPAN: Float = 21000.0
let TILE_PX = 256
let MAX_ZOOM = 8

struct MapCamera {
    /// World-space centre of the viewport.
    var cx: Float = 0
    var cy: Float = 0
    var zoom: Float = 0

    /// Screen points per world metre.
    var scale: Float { Float(TILE_PX) * powf(2.0, zoom) / WORLD_SPAN }

    func worldToView(_ wx: Float, _ wy: Float, viewSize: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(viewSize.x / 2 + (wx - cx) * scale,
              viewSize.y / 2 - (wy - cy) * scale)
    }

    func viewToWorld(_ sx: Float, _ sy: Float, viewSize: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(cx + (sx - viewSize.x / 2) / scale,
              cy - (sy - viewSize.y / 2) / scale)
    }

    /// Keep the world point under the cursor fixed while the scale changes.
    mutating func zoomBy(_ delta: Float, at p: SIMD2<Float>, viewSize: SIMD2<Float>) {
        let before = viewToWorld(p.x, p.y, viewSize: viewSize)
        zoom = min(max(zoom + delta, -1), Float(MAX_ZOOM))
        let after = viewToWorld(p.x, p.y, viewSize: viewSize)
        cx += before.x - after.x
        cy += before.y - after.y
        clampCentre()
    }

    mutating func clampCentre() {
        let lim = WORLD_EXTENT * 1.1
        cx = min(max(cx, -lim), lim)
        cy = min(max(cy, -lim), lim)
    }

    /// Orthographic projection straight to clip space. Metal's NDC z is [0,1],
    /// but a flat map needs no depth, so z is pinned.
    func viewProjection(viewSize: SIMD2<Float>) -> simd_float4x4 {
        let halfW = viewSize.x / (2 * scale)
        let halfH = viewSize.y / (2 * scale)
        let l = cx - halfW, r = cx + halfW
        let b = cy - halfH, t = cy + halfH
        return simd_float4x4(columns: (
            SIMD4(2 / (r - l), 0, 0, 0),
            SIMD4(0, 2 / (t - b), 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(-(r + l) / (r - l), -(t + b) / (t - b), 0, 1)
        ))
    }
}

struct Uniforms { var viewProjection: simd_float4x4 }
struct TileInstance {
    var rect: SIMD4<Float>
    /// Which part of the texture to show: the whole thing for a real tile, one
    /// sub-rect for a coarse ancestor covering this ground.
    var uvRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)
    var fade: Float = 1
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
}
struct MarkerInstance { var world: SIMD2<Float>; var sizePx: Float; var pad: Float = 0 }

/// Markers grouped by symbol, because the glyph is a texture now and every
/// category binds a different one. Fifteen draw calls at worst.
struct MarkerBatch: Sendable {
    var glyph: Glyph
    var colour: SIMD4<Float>
    var instances: [MarkerInstance]
}

/// Byte-budgeted LRU of tile textures. NSCache is not strictly LRU and does not
/// reclaim GPU allocations predictably, so this is hand-rolled.
///
/// Every worker publishes finished tiles into this from its own thread while
/// `draw(in:)` reads it from the render thread, so all four entry points take
/// the lock — an unguarded Dictionary here segfaults under a pan.
final class TextureCache: @unchecked Sendable {
    private var map: [TileKey: MTLTexture] = [:]
    private var order: [TileKey] = []
    private var bytes = 0
    private let budget: Int
    private let lock = NSLock()

    /// Sized for the visible level plus the two it prefetches, with headroom for
    /// the levels you already walked through. 256 KB a tile, so this is ~1500.
    init(budgetMB: Int = 384) { budget = budgetMB * 1024 * 1024 }

    func get(_ k: TileKey) -> MTLTexture? {
        lock.withLock {
            guard let t = map[k] else { return nil }
            if let i = order.firstIndex(of: k) { order.remove(at: i); order.append(k) }
            return t
        }
    }

    func put(_ k: TileKey, _ t: MTLTexture) {
        lock.withLock {
            if map[k] != nil { return }
            map[k] = t
            order.append(k)
            bytes += t.width * t.height * 4
            while bytes > budget, order.count > 1, let oldest = order.first {
                order.removeFirst()
                if let dead = map.removeValue(forKey: oldest) {
                    bytes -= dead.width * dead.height * 4
                }
            }
        }
    }

    func removeAll() { lock.withLock { map.removeAll(); order.removeAll(); bytes = 0 } }
    var count: Int { lock.withLock { map.count } }
}

/// Deliberately not @MainActor: MTKViewDelegate is a nonisolated protocol and
/// draw(in:) is not guaranteed to land on the main thread on macOS.
final class MapRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var tilePipeline: MTLRenderPipelineState!
    private var markerPipeline: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!
    private var quadBuffer: MTLBuffer!

    private let cache = TextureCache()
    /// Second tier behind `cache`: survives the process, so a level you have
    /// already looked at never costs the CPU twice.
    private let store = TileStore()
    private let pool = TilePool()

    private var glyphs: GlyphCache!
    private var _batches: [MarkerBatch] = []

    // State shared with the UI, guarded rather than actor-isolated so the
    // render callback never has to hop isolation domains.
    private let lock = NSLock()
    private var _camera = MapCamera()
    private var _seed: Int32 = 0
    private var _seedName = ""
    private var _gen: Int32 = 2
    private var _mode: Mode = .biome
    private var _palette: Palette = .classic
    private var _needsRedraw = true


    var onStats: (@Sendable (Int, Int) -> Void)?   // (visible tiles, queue depth)
    /// Camera + viewport in points, for overlays that need to place something
    /// at a world position. Only fired when it actually moves — publishing every
    /// frame would drive a SwiftUI update loop.
    var onCamera: (@Sendable (MapCamera, SIMD2<Float>) -> Void)?
    /// Supplied by the view, which owns the display link the transit runs on.
    var flyHandler: ((MapCamera, MapCamera, Double) -> Void)?
    private var lastStats = (-1, -1)
    /// The LOD currently on screen, and whether a zoom gesture is in flight.
    private var lastZ: Int?
    private var zooming = false
    private var lastCam: (Float, Float, Float, Float, Float) = (.nan, .nan, .nan, .nan, .nan)
    weak var view: MTKView?

    var camera: MapCamera {
        get { lock.withLock { _camera } }
        set { lock.withLock { _camera = newValue }; invalidate() }
    }

    init?(view: MTKView) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        super.init()
        self.view = view
        view.device = dev
        // Raw sRGB bytes from the CPU renderer, displayed without a second
        // gamma pass — the same pipeline a browser canvas gives you.
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.clearColor = MTLClearColor(red: 0.0157, green: 0.0275, blue: 0.0549, alpha: 1)

        glyphs = GlyphCache(device: dev)
        guard buildPipelines() else { return nil }
        pool.onTile = { [weak self] result in self?.accept(result, persist: true) }
    }

    private func buildPipelines() -> Bool {
        guard let lib = device.makeDefaultLibrary() else { return false }

        struct QuadVertex { var pos: SIMD2<Float>; var uv: SIMD2<Float> }
        let verts = [
            QuadVertex(pos: [0, 0], uv: [0, 1]), QuadVertex(pos: [1, 0], uv: [1, 1]),
            QuadVertex(pos: [0, 1], uv: [0, 0]), QuadVertex(pos: [1, 1], uv: [1, 0]),
        ]
        quadBuffer = device.makeBuffer(bytes: verts,
                                       length: MemoryLayout<QuadVertex>.stride * 4,
                                       options: .storageModeShared)

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<QuadVertex>.stride

        let td = MTLRenderPipelineDescriptor()
        td.vertexFunction = lib.makeFunction(name: "tile_vertex")
        td.fragmentFunction = lib.makeFunction(name: "tile_fragment")
        td.vertexDescriptor = vd
        td.colorAttachments[0].pixelFormat = .bgra8Unorm
        td.colorAttachments[0].isBlendingEnabled = true
        td.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        td.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

        let md = MTLRenderPipelineDescriptor()
        md.vertexFunction = lib.makeFunction(name: "marker_vertex")
        md.fragmentFunction = lib.makeFunction(name: "marker_fragment")
        md.colorAttachments[0].pixelFormat = .bgra8Unorm
        md.colorAttachments[0].isBlendingEnabled = true
        md.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        md.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        md.colorAttachments[0].sourceAlphaBlendFactor = .one
        md.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sd.maxAnisotropy = 4

        do {
            tilePipeline = try device.makeRenderPipelineState(descriptor: td)
            markerPipeline = try device.makeRenderPipelineState(descriptor: md)
            sampler = device.makeSamplerState(descriptor: sd)
            return true
        } catch {
            NSLog("[map] pipeline build failed: \(error)")
            return false
        }
    }

    // MARK: - Public control

    /// Called once the generator exists, so the pool's workers share it rather
    /// than each paying the 120 ms build and holding their own river grid.
    func setWorld(_ world: WorldGenerator, name: String, gen: Int32) {
        lock.withLock {
            _seedName = name
            _seed = world.seed
            _gen = gen
        }
        // Textures are *not* dropped here. clearForNewSeed already decided,
        // and dropping them unconditionally would throw away the tiles the
        // preload just spent the world-build window reading off disk.
        lastZ = nil
        Task { await pool.configure(world: world); self.invalidate() }
        invalidate()
    }

    /// Clears the map while a new seed's generator is still building.
    ///
    /// Textures only go if the world identity actually changed: re-running the
    /// same seed, or restoring the one from last launch, should keep every
    /// tile it already has. Tiles from a genuinely different world would never
    /// match a key again, so those are worth the ~100 MB they hold.
    func clearForNewSeed(seed: Int32, gen: Int32) {
        let stale = lock.withLock { _seed != seed || _gen != gen }
        lock.withLock { _batches = []; _seedName = "" }
        if stale { cache.removeAll() }
        invalidate()
    }

    /// Read a world's stored tiles back into memory, coarsest first.
    ///
    /// Called before the generator exists, so the world build and the reads
    /// overlap instead of queueing. `draw` returns early until a seed is set,
    /// so nothing is shown mid-fill — the tiles are simply already there when
    /// the map appears.
    ///
    /// Bounded at 200 tiles (~50 MB of texture) rather than everything stored:
    /// levels 0-3 fit inside that whole, which is the opening view plus every
    /// ancestor it can fall back on, and the rest of a fine level arrives
    /// through the normal prefetch within a frame or two.
    func preload(seed: Int32, gen: Int32, mode: Mode, palette: Palette) {
        // Adopt the identity up front. generate() calls clearForNewSeed a
        // moment later and would otherwise see the placeholder seed, judge the
        // cache stale, and drop tiles this is in the middle of reading.
        // `_seedName` stays empty, so draw still shows nothing until the world
        // is actually built.
        lock.withLock { _seed = seed; _gen = gen }
        store.afterScan { [weak self] in
            guard let self else { return }
            let keys = self.store.storedKeys(seed: seed, gen: gen,
                                             mode: mode.rawValue, palette: palette.rawValue,
                                             maxZ: 4, limit: 200)
            guard !keys.isEmpty else { return }
            if ProcessInfo.processInfo.environment["VEG_TRACE"] != nil {
                NSLog("[tiles] preload \(keys.count) stored tiles, seed \(seed)")
            }
            for k in keys {
                self.store.load(k) { [weak self] r in self?.accept(r, persist: false) }
            }
        }
    }

    /// Move the camera over time instead of snapping to it. Duration scales
    /// with how far the view actually travels on screen — a 10 km jump and a
    /// 500 m hop should not take the same beat — plus a little for the dolly.
    func flyTo(_ target: MapCamera) {
        let cur = camera
        guard let fly = flyHandler else { camera = target; return }
        let dx = Double(target.cx - cur.cx), dy = Double(target.cy - cur.cy)
        let pts = (dx * dx + dy * dy).squareRoot() * Double(cur.scale)
        var d = 0.32 + min(pts / 1200.0, 1.0) * 0.20
        d += min(Double(abs(target.zoom - cur.zoom)) * 0.04, 0.12)
        d = min(max(d, 0.32), 0.52)
        // Reduced motion shortens the transit rather than removing it: the
        // teleport is the jarring thing this exists to prevent.
        if DS.reduceMotion { d = 0.15 }
        fly(cur, target, d)
    }

    /// While a zoom gesture runs, hold the current LOD and let the existing
    /// tiles scale. Re-tiling mid-pinch is what reads as the map "refreshing":
    /// every level change invalidates the whole visible set at once.
    func setZooming(_ v: Bool) {
        let changed = lock.withLock { () -> Bool in
            if zooming == v { return false }
            zooming = v
            return true
        }
        if changed { invalidate() }
    }

    func setMode(_ m: Mode) {
        let changed = lock.withLock { () -> Bool in
            if _mode == m { return false }
            _mode = m
            return true
        }
        if changed { invalidate() }
    }

    func setPalette(_ p: Palette) {
        let changed = lock.withLock { () -> Bool in
            if _palette == p { return false }
            _palette = p
            return true
        }
        if changed { invalidate() }
    }

    func setMarkers(_ b: [MarkerBatch]) {
        let changed = lock.withLock { () -> Bool in
            let same = _batches.count == b.count && zip(_batches, b).allSatisfy {
                $0.glyph == $1.glyph && $0.instances.count == $1.instances.count
                    && $0.colour == $1.colour
                    && zip($0.instances, $1.instances).allSatisfy {
                        $0.world == $1.world && $0.sizePx == $1.sizePx
                    }
            }
            if same { return false }
            _batches = b
            return true
        }
        if changed { invalidate() }
    }

    func invalidate() {
        lock.withLock { _needsRedraw = true }
        DispatchQueue.main.async { [weak self] in self?.view?.requestRedraw() }
    }

    /// `persist` is false for a tile that just came *off* disk — otherwise
    /// every read would schedule a write of the bytes it just read.
    private func accept(_ r: TileResult, persist: Bool) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: r.size, height: r.size, mipmapped: true)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }

        // The CPU renderer emits RGBA; the drawable is BGRA. Swap in place.
        var bgra = r.pixels
        for i in stride(from: 0, to: bgra.count, by: 4) {
            bgra.swapAt(i, i + 2)
        }
        bgra.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, r.size, r.size),
                        mipmapLevel: 0, withBytes: raw.baseAddress!,
                        bytesPerRow: r.size * 4)
        }
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
        }
        cache.put(r.key, tex)
        if persist { store.save(r) }
        invalidate()
    }

    // MARK: - MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        invalidate()
    }

    nonisolated func draw(in view: MTKView) {
        lock.lock()
        let cam = _camera
        let seed = _seed, gen = _gen
        let mode = _mode, palette = _palette
        let batches = _batches
        let _seedNameSnapshot = _seedName
        _needsRedraw = false
        let haveSeed = !_seedNameSnapshot.isEmpty
        lock.unlock()

        guard haveSeed else { return }
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }

        let px = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        let scaleFactor = px.x / Float(max(view.bounds.width, 1))
        let viewPts = px / max(scaleFactor, 1)
        let vp = cam.viewProjection(viewSize: viewPts)


        // Which tiles cover the viewport, one LOD finer on HiDPI. Nearest
        // level, plus a dead band a hair wider than the half-level boundary so
        // a zoom parked on it cannot flip back and forth.
        //
        // Holding the level through a gesture — which is what used to happen
        // here — trades one artefact for a worse one: tiles magnify by up to 3x
        // before the level catches up, and the snap back to sharp reads as the
        // map refreshing just as much as a re-tile does. The web has never done
        // anything cleverer than rounding, and it does not show this.
        let ideal = cam.zoom + log2(scaleFactor)
        var zi = Int(ideal.rounded())
        if let cur = lastZ, abs(ideal - Float(cur)) < 0.6 { zi = cur }
        zi = min(max(zi, 0), MAX_ZOOM)
        lastZ = zi
        let tilesPerAxis = 1 << zi
        let tileSpan = WORLD_SPAN / Float(tilesPerAxis)

        let halfW = viewPts.x / (2 * cam.scale), halfH = viewPts.y / (2 * cam.scale)
        let wx0 = cam.cx - halfW, wx1 = cam.cx + halfW
        let wy1 = cam.cy + halfH, wy0 = cam.cy - halfH

        let tx0 = max(0, Int(((wx0 + WORLD_EXTENT) / tileSpan).rounded(.down)))
        let tx1 = min(tilesPerAxis - 1, Int(((wx1 + WORLD_EXTENT) / tileSpan).rounded(.down)))
        let ty0 = max(0, Int(((WORLD_EXTENT - wy1) / tileSpan).rounded(.down)))
        let ty1 = min(tilesPerAxis - 1, Int(((WORLD_EXTENT - wy0) / tileSpan).rounded(.down)))

        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var uniforms = Uniforms(viewProjection: vp)
        enc.setRenderPipelineState(tilePipeline)
        enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)

        var wanted = Set<TileKey>()
        var requests: [TileJob] = []
        var drawn = 0
        var reads = 0

        for ty in ty0...max(ty0, ty1) {
            for tx in tx0...max(tx0, tx1) {
                let key = TileKey(seed: seed, gen: gen, mode: mode.rawValue,
                                  palette: palette.rawValue, z: zi, x: tx, y: ty)
                wanted.insert(key)
                let ox = -WORLD_EXTENT + Float(tx) * tileSpan
                let oy = WORLD_EXTENT - Float(ty) * tileSpan
                let rect = SIMD4<Float>(ox, oy - tileSpan, tileSpan, tileSpan)

                if let tex = cache.get(key) {
                    var inst = TileInstance(rect: rect, fade: 1.0)
                    enc.setVertexBytes(&inst, length: MemoryLayout<TileInstance>.stride, index: 2)
                    enc.setFragmentTexture(tex, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    drawn += 1
                } else {
                    // Progressive refinement. Zooming *in* is covered by a
                    // coarser ancestor; zooming *out* used to leave a hole,
                    // because the four finer tiles that already cover this
                    // ground were never considered.
                    if let (atex, uv) = ancestor(of: key, tx: tx, ty: ty, z: zi) {
                        var inst = TileInstance(rect: rect, uvRect: uv, fade: 1.0)
                        enc.setVertexBytes(&inst, length: MemoryLayout<TileInstance>.stride, index: 2)
                        enc.setFragmentTexture(atex, index: 0)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    } else if zi < MAX_ZOOM, let kids = children(of: key, tx: tx, ty: ty, z: zi) {
                        let half = tileSpan * 0.5
                        for (i, kt) in kids.enumerated() {
                            let kx = ox + Float(i % 2) * half
                            let ky = oy - Float(i / 2) * half
                            var inst = TileInstance(rect: SIMD4(kx, ky - half, half, half), fade: 1.0)
                            enc.setVertexBytes(&inst, length: MemoryLayout<TileInstance>.stride, index: 2)
                            enc.setFragmentTexture(kt, index: 0)
                            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                        }
                    }
                    // Gate the worker on storage rather than racing it: a
                    // stored tile is ~0.3 ms away, and generating it anyway
                    // would burn a core on terrain we already own.
                    //
                    // Before the index exists there is no way to tell those
                    // apart, so ask for nothing: the ancestor already on screen
                    // carries the frame, and the index lands in a millisecond.
                    if !store.indexReady {
                        // nothing to request yet
                    } else if store.has(key) {
                        reads += 1
                        store.load(key) { [weak self] r in self?.accept(r, persist: false) }
                    } else {
                        let ccx = (Float(tx) + 0.5) * tileSpan - WORLD_EXTENT - cam.cx
                        let ccy = WORLD_EXTENT - (Float(ty) + 0.5) * tileSpan - cam.cy
                        requests.append(TileJob(key: key, ox: ox, oy: oy, span: tileSpan,
                                                size: TILE_PX,
                                                priority: Double((ccx * ccx + ccy * ccy).squareRoot())))
                    }
                }
            }
        }

        if !batches.isEmpty {
            enc.setRenderPipelineState(markerPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            var vpPx = viewPts
            enc.setVertexBytes(&vpPx, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            enc.setFragmentSamplerState(sampler, index: 0)
            for b in batches where !b.instances.isEmpty {
                let cg = CGColor(red: CGFloat(b.colour.x), green: CGFloat(b.colour.y),
                                 blue: CGFloat(b.colour.z), alpha: 1)
                guard let gt = glyphs.texture(glyph: b.glyph, colour: cg) else { continue }
                guard let buf = device.makeBuffer(
                    bytes: b.instances,
                    length: MemoryLayout<MarkerInstance>.stride * b.instances.count,
                    options: .storageModeShared) else { continue }
                enc.setVertexBuffer(buf, offset: 0, index: 2)
                enc.setFragmentTexture(gt.texture, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: b.instances.count)
            }
        }


        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        // Prefetch the neighbouring levels once the visible set is satisfied.
        //
        // Every zoom step lands on a level whose ~65 tiles have never been
        // rasterised, and generating them is what reads as the map reloading.
        // Once a level is cached it is free forever — which is exactly why it
        // stops happening after you have been somewhere. So spend the idle time
        // building the levels you are most likely to go to next.
        //
        // These are queued behind everything visible and are kept in `wanted`,
        // otherwise the next frame's cancelExcept would drop them again.
        if requests.isEmpty && !zooming {
            for dz in [1, -1] where zi + dz >= 0 && zi + dz <= MAX_ZOOM {
                let nz = zi + dz
                let n = 1 << nz
                let span = WORLD_SPAN / Float(n)
                // Prefetch the ground that will actually be on screen after one
                // step, not the current rect: zooming in shows a quarter of the
                // area, zooming out four times as much. Using today's rect at
                // z+1 would queue four times the tiles anyone will look at.
                let k: Float = dz > 0 ? 0.5 : 2.0
                let phw = halfW * k, phh = halfH * k
                let px0 = cam.cx - phw, px1 = cam.cx + phw
                let py0 = cam.cy - phh, py1 = cam.cy + phh
                let ax0 = max(0, Int(((px0 + WORLD_EXTENT) / span).rounded(.down)))
                let ax1 = min(n - 1, Int(((px1 + WORLD_EXTENT) / span).rounded(.down)))
                let ay0 = max(0, Int(((WORLD_EXTENT - py1) / span).rounded(.down)))
                let ay1 = min(n - 1, Int(((WORLD_EXTENT - py0) / span).rounded(.down)))
                guard ax1 >= ax0, ay1 >= ay0 else { continue }
                for ty in ay0...ay1 {
                    for tx in ax0...ax1 {
                        let k = TileKey(seed: seed, gen: gen, mode: mode.rawValue,
                                        palette: palette.rawValue, z: nz, x: tx, y: ty)
                        wanted.insert(k)
                        if cache.get(k) != nil { continue }
                        if store.has(k) {
                            reads += 1
                            store.load(k) { [weak self] r in self?.accept(r, persist: false) }
                            continue
                        }
                        let ox = -WORLD_EXTENT + Float(tx) * span
                        let oy = WORLD_EXTENT - Float(ty) * span
                        let ccx = ox + span * 0.5 - cam.cx
                        let ccy = oy - span * 0.5 - cam.cy
                        // +10000 keeps prefetch strictly behind anything the
                        // user can currently see.
                        requests.append(TileJob(key: k, ox: ox, oy: oy, span: span,
                                                size: TILE_PX,
                                                priority: 10000 + Double((ccx * ccx + ccy * ccy).squareRoot())))
                    }
                }
            }
        }

        if ProcessInfo.processInfo.environment["VEG_TRACE"] != nil {
            let pf = requests.filter { $0.priority >= 10000 }.count
            if pf > 0 || reads > 0 || requests.count - pf > 0 {
                let st = store.stats
                NSLog(String(format: "[tiles] z=%d visible=%d need=%d prefetch=%d reads=%d mem=%d disk=%d/%.1fMB",
                             zi, drawn, requests.count - pf, pf, reads, cache.count, st.tiles, st.mb))
            }
        }
        pool.cancelExcept(wanted)
        for r in requests.sorted(by: { $0.priority < $1.priority }) { pool.request(r) }
        let camKey = (cam.cx, cam.cy, cam.zoom, viewPts.x, viewPts.y)
        if camKey != lastCam {
            lastCam = camKey
            onCamera?(cam, viewPts)
        }
        if lastStats != (drawn, requests.count) {
            lastStats = (drawn, requests.count)
            onStats?(drawn, requests.count)
        }
    }

    /// The four tiles one level finer that together cover this one, if the
    /// cache happens to hold all of them. Partial coverage is worse than none —
    /// three quarters of a tile with a hole in it reads as corruption.
    private func children(of key: TileKey, tx: Int, ty: Int, z: Int) -> [MTLTexture]? {
        var out: [MTLTexture] = []
        for dy in 0..<2 {
            for dx in 0..<2 {
                let ck = TileKey(seed: key.seed, gen: key.gen, mode: key.mode,
                                 palette: key.palette, z: z + 1,
                                 x: tx * 2 + dx, y: ty * 2 + dy)
                guard let t = cache.get(ck) else { return nil }
                out.append(t)
            }
        }
        return out
    }

    /// A coarser tile already covering this ground, together with the part of
    /// it that does. The crop is the whole point: `d` levels up, this tile is
    /// one of `4^d` squares inside the ancestor, and showing the ancestor
    /// whole puts a crushed copy of a much larger region in every slot.
    private func ancestor(of key: TileKey, tx: Int, ty: Int, z: Int)
        -> (MTLTexture, SIMD4<Float>)? {
        var d = 1
        while d <= z {
            let ak = TileKey(seed: key.seed, gen: key.gen, mode: key.mode, palette: key.palette,
                             z: z - d, x: tx >> d, y: ty >> d)
            if let t = cache.get(ak) {
                let span = 1 << d
                let sub = 1.0 / Float(span)
                // v runs the same way as the tile y index: row 0 of the
                // texture is the tile's north edge.
                return (t, SIMD4(Float(tx & (span - 1)) * sub,
                                 Float(ty & (span - 1)) * sub, sub, sub))
            }
            d += 1
        }
        return nil
    }

}

extension MTKView {
    /// The invalidation entry point differs between AppKit and UIKit.
    func requestRedraw() {
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }
}

extension NSLock {
    @inline(__always) func withLock<R>(_ body: () -> R) -> R {
        lock(); defer { unlock() }; return body()
    }
}
