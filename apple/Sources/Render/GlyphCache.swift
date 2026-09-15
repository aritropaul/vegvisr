//  GlyphCache.swift
//  Marker symbology, rasterised once per category.
//
//  These are ports of the web build's `glyph()` paths — flat instrument
//  symbology, not map-app pins: a dark halo stroke, a translucent dark fill,
//  then a thin stroke in the category colour. Drawing them as real paths through
//  Core Graphics is both more faithful and far less work than approximating
//  fourteen outlines as signed-distance fields in MSL.

import Foundation
import Metal
import CoreGraphics

enum Glyph: Int, Sendable {
    case spawn, diamond, triangle, square, hex, arch, keep, coin
    case rune, ruin, house, hull, menhir, node, sigil
}

struct GlyphTexture {
    let texture: MTLTexture
    /// Half-extent of the drawing in units of the marker radius, so the quad
    /// can be sized from a radius alone.
    let extent: Float
}

final class GlyphCache {
    private var cache: [Int: GlyphTexture] = [:]
    var cacheCount: Int { cache.count }
    private let device: MTLDevice
    private let blitQueue: MTLCommandQueue?

    /// Rasterisation radius. Strokes are scaled from the web's 5.5 px reference
    /// radius so the proportions hold when the texture is scaled down.
    private let R: CGFloat = 30
    private let extentR: CGFloat = 1.6      // spawn's crosshair reaches 1.5r
    private let px = 96

    init(device: MTLDevice) {
        self.device = device
        self.blitQueue = device.makeCommandQueue()
    }

    func texture(glyph: Glyph, colour: CGColor) -> GlyphTexture? {
        let key = glyph.rawValue &* 31 &+ colourKey(colour)
        if let hit = cache[key] { return hit }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: px * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        let c = CGPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2)
        let scale = R / 5.5      // web reference radius

        // 1. Dark halo, so the glyph survives white mountain and pale sand.
        ctx.setStrokeColor(CGColor(red: 0.008, green: 0.02, blue: 0.043, alpha: 0.92))
        ctx.setLineWidth(3.0 * scale)
        path(glyph, ctx, c, R)
        ctx.strokePath()

        // 2. Translucent dark fill, then the category-coloured stroke.
        ctx.setFillColor(CGColor(red: 0.008, green: 0.02, blue: 0.043, alpha: 0.62))
        ctx.setStrokeColor(colour)
        ctx.setLineWidth(1.35 * scale)
        path(glyph, ctx, c, R)
        ctx.drawPath(using: .fillStroke)

        guard let image = ctx.makeImage() else { return nil }
        var bytes = [UInt8](repeating: 0, count: px * px * 4)
        guard let out = CGContext(data: &bytes, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: px * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        out.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: px, height: px, mipmapped: true)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        bytes.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, px, px), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: px * 4)
        }
        // Build the mip chain now and wait for it. These are drawn as small as
        // 6 pt, so the sampler reaches deep into the chain immediately — leaving
        // it to a later, unsynchronised blit means the first frames sample
        // undefined levels and the glyph simply does not appear.
        if let q = blitQueue, let cb = q.makeCommandBuffer(),
           let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }

        let entry = GlyphTexture(texture: tex, extent: Float(extentR))
        cache[key] = entry
        return entry
    }

    private func colourKey(_ c: CGColor) -> Int {
        let comps = c.components ?? [1, 1, 1, 1]
        return Int(comps[0] * 255) << 16 | Int(comps[1] * 255) << 8 | Int(comps[2] * 255)
    }

    /// Ports of the web build's `glyph()` switch, one for one.
    private func path(_ g: Glyph, _ ctx: CGContext, _ o: CGPoint, _ r: CGFloat) {
        let x = o.x, y = o.y
        ctx.beginPath()
        switch g {
        case .diamond:
            ctx.move(to: CGPoint(x: x, y: y - r))
            ctx.addLine(to: CGPoint(x: x + r, y: y))
            ctx.addLine(to: CGPoint(x: x, y: y + r))
            ctx.addLine(to: CGPoint(x: x - r, y: y))
            ctx.closePath()
        case .triangle:
            ctx.move(to: CGPoint(x: x, y: y - r))
            ctx.addLine(to: CGPoint(x: x + r * 0.92, y: y + r * 0.72))
            ctx.addLine(to: CGPoint(x: x - r * 0.92, y: y + r * 0.72))
            ctx.closePath()
        case .square:
            ctx.addRect(CGRect(x: x - r * 0.78, y: y - r * 0.78, width: r * 1.56, height: r * 1.56))
        case .hex:
            for i in 0..<6 {
                let a = (CGFloat.pi / 3) * CGFloat(i) - .pi / 2
                let p = CGPoint(x: x + cos(a) * r, y: y + sin(a) * r)
                i == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
            }
            ctx.closePath()
        case .arch:
            ctx.move(to: CGPoint(x: x - r * 0.85, y: y + r * 0.7))
            ctx.addLine(to: CGPoint(x: x - r * 0.85, y: y))
            ctx.addArc(center: CGPoint(x: x, y: y), radius: r * 0.85,
                       startAngle: .pi, endAngle: 0, clockwise: false)
            ctx.addLine(to: CGPoint(x: x + r * 0.85, y: y + r * 0.7))
            ctx.closePath()
        case .keep:
            ctx.move(to: CGPoint(x: x - r, y: y + r * 0.8))
            ctx.addLine(to: CGPoint(x: x - r, y: y - r * 0.35))
            ctx.addLine(to: CGPoint(x: x - r * 0.45, y: y - r * 0.35))
            ctx.addLine(to: CGPoint(x: x - r * 0.45, y: y - r))
            ctx.addLine(to: CGPoint(x: x + r * 0.45, y: y - r))
            ctx.addLine(to: CGPoint(x: x + r * 0.45, y: y - r * 0.35))
            ctx.addLine(to: CGPoint(x: x + r, y: y - r * 0.35))
            ctx.addLine(to: CGPoint(x: x + r, y: y + r * 0.8))
            ctx.closePath()
        case .coin:
            ctx.addEllipse(in: CGRect(x: x - r * 0.88, y: y - r * 0.88, width: r * 1.76, height: r * 1.76))
            ctx.addEllipse(in: CGRect(x: x - r * 0.3, y: y - r * 0.3, width: r * 0.6, height: r * 0.6))
        case .rune:
            ctx.move(to: CGPoint(x: x - r * 0.6, y: y + r))
            ctx.addLine(to: CGPoint(x: x - r * 0.6, y: y - r * 0.3))
            ctx.addArc(center: CGPoint(x: x, y: y - r * 0.3), radius: r * 0.6,
                       startAngle: .pi, endAngle: 0, clockwise: false)
            ctx.addLine(to: CGPoint(x: x + r * 0.6, y: y + r))
            ctx.closePath()
        case .ruin:
            ctx.addRect(CGRect(x: x - r * 0.85, y: y - r * 0.2, width: r * 0.5, height: r * 1.2))
            ctx.addRect(CGRect(x: x + r * 0.2, y: y - r * 0.9, width: r * 0.5, height: r * 1.9))
        case .house:
            ctx.move(to: CGPoint(x: x, y: y - r))
            ctx.addLine(to: CGPoint(x: x + r * 0.9, y: y - r * 0.1))
            ctx.addLine(to: CGPoint(x: x + r * 0.9, y: y + r * 0.85))
            ctx.addLine(to: CGPoint(x: x - r * 0.9, y: y + r * 0.85))
            ctx.addLine(to: CGPoint(x: x - r * 0.9, y: y - r * 0.1))
            ctx.closePath()
        case .hull:
            ctx.move(to: CGPoint(x: x - r, y: y - r * 0.1))
            ctx.addQuadCurve(to: CGPoint(x: x + r, y: y - r * 0.1),
                             control: CGPoint(x: x, y: y + r * 0.95))
            ctx.closePath()
            ctx.move(to: CGPoint(x: x, y: y - r * 0.15))
            ctx.addLine(to: CGPoint(x: x, y: y - r))
        case .menhir:
            ctx.move(to: CGPoint(x: x, y: y - r))
            ctx.addLine(to: CGPoint(x: x + r * 0.45, y: y + r))
            ctx.addLine(to: CGPoint(x: x - r * 0.45, y: y + r))
            ctx.closePath()
            ctx.move(to: CGPoint(x: x - r * 0.8, y: y + r))
            ctx.addLine(to: CGPoint(x: x + r * 0.8, y: y + r))
        case .node:
            for i in 0..<3 {
                let a = (CGFloat.pi / 3) * CGFloat(i)
                ctx.move(to: CGPoint(x: x - cos(a) * r, y: y - sin(a) * r))
                ctx.addLine(to: CGPoint(x: x + cos(a) * r, y: y + sin(a) * r))
            }
        case .sigil:
            ctx.addEllipse(in: CGRect(x: x - r * 0.9, y: y - r * 0.9, width: r * 1.8, height: r * 1.8))
            ctx.addEllipse(in: CGRect(x: x - r * 0.22, y: y - r * 0.22, width: r * 0.44, height: r * 0.44))
        case .spawn:
            ctx.addEllipse(in: CGRect(x: x - r * 0.7, y: y - r * 0.7, width: r * 1.4, height: r * 1.4))
            ctx.move(to: CGPoint(x: x - r * 1.5, y: y)); ctx.addLine(to: CGPoint(x: x - r * 0.9, y: y))
            ctx.move(to: CGPoint(x: x + r * 0.9, y: y)); ctx.addLine(to: CGPoint(x: x + r * 1.5, y: y))
            ctx.move(to: CGPoint(x: x, y: y - r * 1.5)); ctx.addLine(to: CGPoint(x: x, y: y - r * 0.9))
            ctx.move(to: CGPoint(x: x, y: y + r * 0.9)); ctx.addLine(to: CGPoint(x: x, y: y + r * 1.5))
        }
    }
}

extension GlyphCache {
    var count: Int { cacheCount }
}
