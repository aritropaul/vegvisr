//  MarkerProbe.swift
//  Renders the real marker pipeline into an offscreen texture so the glyphs can
//  be checked without a screen-capture grant. Debug utility, macOS only.

#if os(macOS)
import Metal
import MetalKit
import AppKit
import simd

enum MarkerProbe {
    static func run(to path: String) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary() else { exit(1) }

        let W = 900, H = 230
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let target = device.makeTexture(descriptor: td) else { exit(1) }

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "marker_vertex")
        pd.fragmentFunction = lib.makeFunction(name: "marker_fragment")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd) else { exit(1) }

        // Every category at the three sizes that matter: the clamp floor, the
        // middle of the range, and the clamp ceiling.
        let cache = GlyphCache(device: device)
        struct Draw { let tex: MTLTexture; let inst: MarkerInstance }
        var draws: [Draw] = []
        for (i, c) in POI_KINDS.enumerated() {
            let cg = CGColor(red: CGFloat(c.rgba.x), green: CGFloat(c.rgba.y),
                             blue: CGFloat(c.rgba.z), alpha: 1)
            guard let gt = cache.texture(glyph: c.glyph, colour: cg) else { continue }
            let x = Float(i) * 58 + 40
            for (j, d) in [Float(16), 11, 6].enumerated() {
                draws.append(Draw(tex: gt.texture,
                                  inst: MarkerInstance(world: SIMD2(x, 55 + Float(j) * 62),
                                                       sizePx: d * 1.6)))
            }
        }

        // Orthographic 1:1 with the texture, y down.
        let l: Float = 0, r = Float(W), t: Float = 0, b = Float(H)
        var u = Uniforms(viewProjection: simd_float4x4(columns: (
            SIMD4(2 / (r - l), 0, 0, 0),
            SIMD4(0, 2 / (t - b), 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(-(r + l) / (r - l), -(t + b) / (t - b), 0, 1)
        )))

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.12, blue: 0.20, alpha: 1)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { exit(1) }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        var vp = SIMD2<Float>(Float(W), Float(H))
        enc.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        let sd2 = MTLSamplerDescriptor()
        sd2.minFilter = .linear; sd2.magFilter = .linear; sd2.mipFilter = .linear
        if let samp = device.makeSamplerState(descriptor: sd2) {
            enc.setFragmentSamplerState(samp, index: 0)
        }
        for d in draws {
            var inst = d.inst
            enc.setVertexBytes(&inst, length: MemoryLayout<MarkerInstance>.stride, index: 2)
            enc.setFragmentTexture(d.tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        target.getBytes(&bytes, bytesPerRow: W * 4,
                        from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) }  // BGRA -> RGBA

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &bytes, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: W * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let img = ctx.makeImage() else { exit(1) }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write("wrote \(path)\n".data(using: .utf8)!)
        exit(0)
    }
}
#endif
