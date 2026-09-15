//  LodProbe.swift
//  Checks the coarse-tile stand-in against ground truth.
//
//  When a tile is not ready the renderer draws a coarser ancestor over the same
//  ground. That is only correct if the quad samples the part of the ancestor
//  that covers this tile; sampling all of it puts a crushed copy of a 4x (or
//  16x) larger region in every slot, which is what the map "refreshing" was.
//
//  Reasoning about that is how it stayed broken, so this measures it: draw one
//  viewport three ways through the real pipeline and compare pixels.

#if os(macOS)
import Metal
import MetalKit
import AppKit
import simd
import Worldgen

enum LodProbe {
    private struct QuadVertex { var pos: SIMD2<Float>; var uv: SIMD2<Float> }

    static func run(to path: String, seed: String) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary() else { exit(1) }

        let side = 512
        let wg = WorldGenerator(seedName: seed, worldGenVersion: 2)
        let tr = TileRenderer(wg)

        func tile(z: Int, x: Int, y: Int) -> MTLTexture {
            let n = 1 << z
            let span = WORLD_SPAN / Float(n)
            tr.render(ox: -WORLD_EXTENT + Float(x) * span,
                      oy: WORLD_EXTENT - Float(y) * span,
                      span: span, size: TILE_PX, mode: .biome, palette: .classic)
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: TILE_PX, height: TILE_PX, mipmapped: false)
            d.usage = [.shaderRead]; d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { exit(1) }
            tr.withPixels { p in
                t.replace(region: MTLRegionMake2D(0, 0, TILE_PX, TILE_PX), mipmapLevel: 0,
                          withBytes: p.baseAddress!, bytesPerRow: TILE_PX * 4)
            }
            return t
        }

        // z=1 is 2x2 tiles over the world, z=2 is 4x4. Every z=2 tile therefore
        // has exactly one z=1 ancestor one level up.
        var z1: [MTLTexture] = []
        for y in 0..<2 { for x in 0..<2 { z1.append(tile(z: 1, x: x, y: y)) } }
        var z2: [MTLTexture] = []
        for y in 0..<4 { for x in 0..<4 { z2.append(tile(z: 2, x: x, y: y)) } }

        // Same quad and pipeline the map uses.
        let verts = [
            QuadVertex(pos: [0, 0], uv: [0, 1]), QuadVertex(pos: [1, 0], uv: [1, 1]),
            QuadVertex(pos: [0, 1], uv: [0, 0]), QuadVertex(pos: [1, 1], uv: [1, 0]),
        ]
        guard let quad = device.makeBuffer(bytes: verts,
                                           length: MemoryLayout<QuadVertex>.stride * 4,
                                           options: .storageModeShared) else { exit(1) }
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 8; vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<QuadVertex>.stride
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "tile_vertex")
        pd.fragmentFunction = lib.makeFunction(name: "tile_fragment")
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd) else { exit(1) }

        let sdesc = MTLSamplerDescriptor()
        sdesc.minFilter = .linear; sdesc.magFilter = .linear
        sdesc.sAddressMode = .clampToEdge; sdesc.tAddressMode = .clampToEdge
        let samp = device.makeSamplerState(descriptor: sdesc)

        // The whole world, orthographic, exactly as MapCamera would frame it.
        var u = Uniforms(viewProjection: simd_float4x4(columns: (
            SIMD4(1 / WORLD_EXTENT, 0, 0, 0), SIMD4(0, 1 / WORLD_EXTENT, 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))))

        /// Draw the 4x4 z=2 grid, choosing texture and sub-rect per slot.
        func render(_ pick: (Int, Int) -> (MTLTexture, SIMD4<Float>)) -> [UInt8] {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
            guard let out = device.makeTexture(descriptor: d) else { exit(1) }
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = out
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            guard let cb = queue.makeCommandBuffer(),
                  let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { exit(1) }
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(quad, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentSamplerState(samp, index: 0)
            let span = WORLD_SPAN / 4
            for ty in 0..<4 {
                for tx in 0..<4 {
                    let ox = -WORLD_EXTENT + Float(tx) * span
                    let oy = WORLD_EXTENT - Float(ty) * span
                    let (tex, uv) = pick(tx, ty)
                    var inst = TileInstance(rect: SIMD4(ox, oy - span, span, span),
                                            uvRect: uv, fade: 1.0)
                    enc.setVertexBytes(&inst, length: MemoryLayout<TileInstance>.stride, index: 2)
                    enc.setFragmentTexture(tex, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: side * side * 4)
            out.getBytes(&px, bytesPerRow: side * 4,
                         from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
            return px
        }

        let truth = render { tx, ty in (z2[ty * 4 + tx], SIMD4(0, 0, 1, 1)) }
        // What the renderer does now: the ancestor's own quarter.
        let cropped = render { tx, ty in
            (z1[(ty >> 1) * 2 + (tx >> 1)],
             SIMD4(Float(tx & 1) * 0.5, Float(ty & 1) * 0.5, 0.5, 0.5))
        }
        // What it did before: the whole ancestor in every slot.
        let whole = render { tx, ty in (z1[(ty >> 1) * 2 + (tx >> 1)], SIMD4(0, 0, 1, 1)) }

        func meanDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var sum = 0
            for i in stride(from: 0, to: a.count, by: 4) {
                sum += abs(Int(a[i]) - Int(b[i]))
                    + abs(Int(a[i + 1]) - Int(b[i + 1]))
                    + abs(Int(a[i + 2]) - Int(b[i + 2]))
            }
            return Double(sum) / Double(a.count / 4 * 3)
        }

        let dCrop = meanDiff(cropped, truth)
        let dWhole = meanDiff(whole, truth)
        FileHandle.standardError.write("""
            stand-in vs real tiles, mean per-channel error out of 255:
              cropped ancestor (now)      \(String(format: "%6.2f", dCrop))
              whole ancestor (before)     \(String(format: "%6.2f", dWhole))
              ratio                       \(String(format: "%6.2fx", dWhole / max(dCrop, 0.001)))

            """.data(using: .utf8)!)

        // Side by side: truth | cropped | whole.
        let W = side * 3
        var strip = [UInt8](repeating: 0, count: W * side * 4)
        for (panel, src) in [truth, cropped, whole].enumerated() {
            for y in 0..<side {
                let dst = (y * W + panel * side) * 4
                let s = y * side * 4
                for i in 0..<(side * 4) { strip[dst + i] = src[s + i] }
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &strip, width: W, height: side, bitsPerComponent: 8,
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
