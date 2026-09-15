//  MapShot.swift
//  Renders terrain + the real marker pipeline into one offscreen image, so
//  markers can be judged over actual ground rather than a flat swatch.

#if os(macOS)
import Metal
import MetalKit
import AppKit
import simd
import Worldgen

enum MapShot {
    static func run(to path: String, span: Float, seed: String) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary() else { exit(1) }

        let W = 1024, H = 1024
        let wg = WorldGenerator(seedName: seed, worldGenVersion: 2)

        // Terrain underneath, at the aspect of the viewport.
        let tileN = 1024
        let tr = TileRenderer(wg)
        tr.render(ox: -span / 2, oy: span / 2,
                  span: span, size: tileN, mode: .terrain, palette: .classic)
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: tileN, height: tileN, mipmapped: false)
        td.usage = [.shaderRead]; td.storageMode = .shared
        guard let tileTex = device.makeTexture(descriptor: td) else { exit(1) }
        tr.withPixels { p in
            tileTex.replace(region: MTLRegionMake2D(0, 0, tileN, tileN), mipmapLevel: 0,
                            withBytes: p.baseAddress!, bytesPerRow: tileN * 4)
        }

        // Only the prioritised types are needed for spawn/boss/trader markers.
        let st = beginLocations()
        _ = stepLocations(wg, st, 23)
        let lm = buildLandmass(wg)
        let sites: [Site] = st.placed.map { p in
            let c = LOCATIONS[p.cfg]
            return Site(kind: c.kind, label: c.label, x: p.x, y: p.y,
                        reachable: lm.nearestLand(p.x, p.y, 6) == lm.spawn)
        }
        FileHandle.standardError.write("sites: \(sites.count)\n".data(using: .utf8)!)

        let target = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        target.usage = [.renderTarget, .shaderRead]; target.storageMode = .shared
        guard let out = device.makeTexture(descriptor: target) else { exit(1) }

        // World -> clip, matching MapCamera's orthographic projection.
        let halfW = span / 2
        let halfH = span / 2
        var u = Uniforms(viewProjection: simd_float4x4(columns: (
            SIMD4(1 / halfW, 0, 0, 0), SIMD4(0, 1 / halfH, 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))))

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = out
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.0157, green: 0.0275, blue: 0.0549, alpha: 1)

        struct QV { var pos: SIMD2<Float>; var uv: SIMD2<Float> }
        let quad = [QV(pos: [0,0], uv: [0,1]), QV(pos: [1,0], uv: [1,1]),
                    QV(pos: [0,1], uv: [0,0]), QV(pos: [1,1], uv: [1,0])]
        let qb = device.makeBuffer(bytes: quad, length: MemoryLayout<QV>.stride * 4, options: .storageModeShared)
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<QV>.stride

        let tp = MTLRenderPipelineDescriptor()
        tp.vertexFunction = lib.makeFunction(name: "tile_vertex")
        tp.fragmentFunction = lib.makeFunction(name: "tile_fragment")
        tp.vertexDescriptor = vd
        tp.colorAttachments[0].pixelFormat = .bgra8Unorm

        let mp = MTLRenderPipelineDescriptor()
        mp.vertexFunction = lib.makeFunction(name: "marker_vertex")
        mp.fragmentFunction = lib.makeFunction(name: "marker_fragment")
        mp.colorAttachments[0].pixelFormat = .bgra8Unorm
        mp.colorAttachments[0].isBlendingEnabled = true
        mp.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        mp.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        mp.colorAttachments[0].sourceAlphaBlendFactor = .one
        mp.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge

        guard let tps = try? device.makeRenderPipelineState(descriptor: tp),
              let mps = try? device.makeRenderPipelineState(descriptor: mp),
              let sampler = device.makeSamplerState(descriptor: sd),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { exit(1) }

        enc.setRenderPipelineState(tps)
        enc.setVertexBuffer(qb, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        var inst = TileInstance(rect: SIMD4(-span/2, -span/2, span, span), fade: 1)
        enc.setVertexBytes(&inst, length: MemoryLayout<TileInstance>.stride, index: 2)
        enc.setFragmentTexture(tileTex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        let cache = GlyphCache(device: device)
        let visible = sites.filter { [0, 1, 2].contains($0.kind.rawValue) }
        func side(_ k: Kind) -> Float {
            var d: Float = 12
            switch k { case .spawn, .boss: d *= 1.15; case .trader: d *= 1.05; default: break }
            return min(max(d, 6), 16) * 1.6
        }
        enc.setRenderPipelineState(mps)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        var vp = SIMD2<Float>(Float(W), Float(H))
        enc.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.setFragmentSamplerState(sampler, index: 0)
        for s in visible {
            guard let cat = POI_KINDS.first(where: { $0.kind == s.kind }) else { continue }
            let cg = CGColor(red: CGFloat(cat.rgba.x), green: CGFloat(cat.rgba.y),
                             blue: CGFloat(cat.rgba.z), alpha: 1)
            guard let gt = cache.texture(glyph: cat.glyph, colour: cg) else { continue }
            var inst = MarkerInstance(world: SIMD2(s.x, s.y), sizePx: side(s.kind))
            enc.setVertexBytes(&inst, length: MemoryLayout<MarkerInstance>.stride, index: 2)
            enc.setFragmentTexture(gt.texture, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        out.getBytes(&bytes, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: W * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let img = ctx.makeImage() else { exit(1) }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write("wrote \(path)\n".data(using: .utf8)!)
        exit(0)
    }
}
#endif
