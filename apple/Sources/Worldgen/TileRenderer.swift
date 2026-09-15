//  TileRenderer.swift
//  Tile rasterisation: world coordinates -> RGBA pixels.
//
//  Two modes, one look. Everything is drawn as luminous ink over a near-black
//  ground: biome identity is carried by hue, terrain by relief and contour
//  lines. Both modes share one sampling pass that fills an apron grid of
//  (biome, height), which is what lets biome borders blur and relief normals
//  stay seamless across tile edges.

import Foundation

public enum Mode: Int32, Sendable {
    /// Biome fields: soft luminous regions with gradient borders.
    case biome = 0
    /// Terrain: relief shading with iso-contours over the same fields.
    case terrain = 1
}

public enum Palette: Int32, Sendable {
    /// Naturalistic hues, rendered emissively.
    case classic = 0
    /// Hue *and* luminance separated for red-green colour blindness.
    case accessible = 1
}

/// Ground the whole map sits on.
private let BACKDROP: SIMD3<Float> = [5.0, 8.0, 16.0]
private let SHORE: SIMD3<Float> = [126.0, 232.0, 255.0]

/// Emissive ink per biome. Hues follow the terrain as it actually looks, but
/// lifted to luminances that read against a near-black ground.
@inline(__always)
func ink(_ b: Biome, _ p: Palette) -> SIMD3<Float> {
    switch p {
    case .classic:
        switch b {
        case .meadows:     return [168, 224, 95]   // light grassy green
        case .blackForest: return [47, 125, 79]    // dark forest green
        case .swamp:       return [154, 123, 69]   // muddy brown
        case .plains:      return [217, 184, 118]  // sandy brown
        case .mountain:    return [220, 233, 242]
        case .mistlands:   return [138, 123, 200]
        case .ashLands:    return [224, 85, 47]
        case .deepNorth:   return [159, 216, 240]
        case .ocean:       return [38, 84, 196]
        case .none:        return [120, 120, 120]
        }
    case .accessible:
        // Pushed apart in hue AND luminance so the greens and the two pale
        // biomes stay separable without colour discrimination.
        switch b {
        case .meadows:     return [198, 240, 96]
        case .blackForest: return [40, 158, 220]
        case .swamp:       return [244, 118, 206]
        case .plains:      return [246, 196, 62]
        case .mountain:    return [255, 255, 255]
        case .mistlands:   return [176, 128, 255]
        case .ashLands:    return [255, 128, 54]
        case .deepNorth:   return [126, 226, 255]
        case .ocean:       return [58, 104, 226]
        case .none:        return [140, 140, 140]
        }
    }
}

/// How wet a sample is, 0 = dry land, 1 = open water.
///
/// A hard `h < WATER_LEVEL` test dithers badly: terrain roughness is about
/// ±2 m, so ground near sea level flickers pixel to pixel. Swamp is the worst
/// case — it generates at ~27 m, just under sea level — so marsh is
/// additionally capped, because it is ankle-deep bog rather than sea.
@inline(__always)
func wetness(_ h: Float, _ b: Biome) -> Float {
    let w = smoothStepF(WATER_LEVEL + 2.0, WATER_LEVEL - 2.5, h)
    return b == .swamp ? min(w, 0.30) : w
}

/// Apron width, sized for the widest blend radius we ever use.
///
/// INVARIANT: the hue blur runs two box passes per axis, each eroding `r` of
/// valid data per side, so the apron must be at least `2 * maxRadius`. That is
/// why `blendRadius` clamps to PAD/2. Change one of these three and you must
/// change the others, or tile edges silently sample stale apron data.
let PAD = 14

/// Biome boundaries blend over this many WORLD METRES, not a fixed pixel count.
/// A fixed pixel radius is wrong at both ends: zoomed in it is invisible, and
/// zoomed out it is wider than the biome patches themselves.
private let BLEND_METRES: Float = 120.0

/// Two box passes per axis compose into a tent whose full ramp is `4 * r`
/// pixels, so solve that for the target ground distance.
@inline(__always)
func blendRadius(_ metresPerPx: Float) -> Int {
    min(max(Int((BLEND_METRES / (4.0 * metresPerPx)).rounded()), 1), PAD / 2)
}

@inline(__always)
func ordOf(_ b: Biome) -> UInt8 {
    switch b {
    case .none: return 0; case .meadows: return 1; case .swamp: return 2
    case .mountain: return 3; case .blackForest: return 4; case .plains: return 5
    case .ashLands: return 6; case .deepNorth: return 7; case .ocean: return 8
    case .mistlands: return 9
    }
}

@inline(__always)
func unord(_ o: UInt8) -> Biome {
    switch o {
    case 1: return .meadows; case 2: return .swamp; case 3: return .mountain
    case 4: return .blackForest; case 5: return .plains; case 6: return .ashLands
    case 7: return .deepNorth; case 8: return .ocean; case 9: return .mistlands
    default: return .none
    }
}

public final class TileRenderer {
    public let wg: WorldGenerator
    private var pixels: [UInt8] = []
    private var heights: [Float] = []
    private var biomes: [UInt8] = []
    /// Per-sample biome ink, and its blurred copy. Only the hue field is
    /// blurred; shading and contours are computed per-pixel afterwards so they
    /// stay crisp while region boundaries gradient.
    private var hue: [Float] = []
    private var hueBlur: [Float] = []
    private var size: Int = 0

    public init(_ wg: WorldGenerator) { self.wg = wg }

    private func ensure(_ s: Int) {
        if size != s {
            let w = s + 2 * PAD
            pixels = [UInt8](repeating: 0, count: s * s * 4)
            heights = [Float](repeating: 0, count: w * w)
            biomes = [UInt8](repeating: 0, count: w * w)
            hue = [Float](repeating: 0, count: w * w * 3)
            hueBlur = [Float](repeating: 0, count: w * w * 3)
            size = s
        }
    }

    /// Valid until the next render() on this instance.
    public func withPixels<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        pixels.withUnsafeBufferPointer(body)
    }

    public func copyPixels() -> [UInt8] { pixels }

    /// Separable blur of the hue field using running-sum box passes: O(1) per
    /// pixel regardless of radius. Two passes per axis compose into a tent,
    /// which ramps without the flat-topped banding a single box leaves.
    private func blurHue(_ w: Int, _ r: Int) {
        for _ in 0..<2 { boxH(&hue, &hueBlur, w, r); swap(&hue, &hueBlur) }
        for _ in 0..<2 { boxV(&hue, &hueBlur, w, r); swap(&hue, &hueBlur) }
    }

    /// Rasterise one square tile. `ox` is the west edge and `oy` the NORTH
    /// edge; rows advance southward so north renders upward on screen.
    public func render(ox: Float, oy: Float, span: Float, size s: Int,
                       mode: Mode, palette: Palette) {
        ensure(s)
        let step = span / Float(s)
        let n = s
        let hw = n + 2 * PAD

        biomes.withUnsafeMutableBufferPointer { bp in
        heights.withUnsafeMutableBufferPointer { hp in
        hue.withUnsafeMutableBufferPointer { up in
            for gy in 0..<hw {
                let wy = oy - (Float(gy) - Float(PAD)) * step
                for gx in 0..<hw {
                    let wx = ox + (Float(gx) - Float(PAD)) * step
                    let (b, base) = wg.biomeWithBase(wx, wy)
                    let i = gy * hw + gx
                    bp[i] = ordOf(b)
                    hp[i] = wg.biomeHeightWithBase(b, wx, wy, base)
                    let c = ink(b, palette)
                    up[i * 3] = c.x; up[i * 3 + 1] = c.y; up[i * 3 + 2] = c.z
                }
            }
        }}}

        blurHue(hw, blendRadius(step))

        let contours = mode == .terrain
        let interval = contourInterval(step)
        let sea = ink(.ocean, palette)

        biomes.withUnsafeBufferPointer { bp in
        heights.withUnsafeBufferPointer { hp in
        hue.withUnsafeBufferPointer { up in
        pixels.withUnsafeMutableBufferPointer { px in
            for py in 0..<n {
                for pxi in 0..<n {
                    let gi = (py + PAD) * hw + (pxi + PAD)
                    let b = unord(bp[gi])
                    let h = hp[gi]
                    let wet = wetness(h, b)
                    // The blurred field is used directly: across a boundary it
                    // is one continuous ramp, and in a region interior it
                    // already equals that biome's own colour. Do NOT bias each
                    // pixel back toward its own pure hue — the pure hue flips
                    // at the boundary, so each side pulls toward a different
                    // colour and the ramp becomes two half-ramps with a step
                    // between them, re-sharpening the edge the blur softens.
                    var hue3 = SIMD3<Float>(up[gi * 3], up[gi * 3 + 1], up[gi * 3 + 2])

                    let dzdx = (hp[gi + 1] - hp[gi - 1]) * 0.5
                    let dzdy = (hp[gi + hw] - hp[gi - hw]) * 0.5

                    // Submerged ground reads as water, not as a dim version of
                    // its biome: terrain below sea level is still *classified*
                    // as Meadows, Black Forest and so on.
                    let depthT = min(max((WATER_LEVEL - h) < 0 ? 0 : (WATER_LEVEL - h), 0.0) / 100.0, 1.0)
                    hue3 += (sea - hue3) * wet

                    // Water is muted hard so land carries the whole image and
                    // the coastline is the strongest contrast edge on the map.
                    let waterGain = 0.20 - depthT * 0.115
                    let landGain: Float

                    if contours {
                        // Two-light hillshade. A single lamp flattens ridges
                        // running parallel to it; a dimmer opposite fill
                        // recovers them.
                        let zExag = max(step * 0.6, 1.0)
                        let nx = -dzdx * zExag / step
                        let ny = -dzdy * zExag / step
                        let inv = 1.0 / (nx * nx + ny * ny + 1.0).squareRoot()
                        let key = min(max((nx * -0.62 + ny * -0.62 + 1.0) * inv, 0.0), 1.8)
                        let fill = min(max((nx * 0.5 + ny * 0.55 + 1.0) * inv, 0.0), 1.8)
                        let slope = min((nx * nx + ny * ny).squareRoot(), 2.5)
                        let ao = 1.0 - min(slope * 0.16, 0.34)
                        landGain = (0.20 + key * 0.34 + fill * 0.10) * ao
                    } else {
                        // Flat fields with only a whisper of relief, so regions
                        // read as regions.
                        let emboss = min(max((dzdx + dzdy) / (step * 2.2), -0.6), 0.6)
                        landGain = 0.40 * (1.0 + emboss * 0.22)
                    }

                    let gain = landGain + (waterGain - landGain) * wet
                    var out = BACKDROP + hue3 * gain

                    if contours {
                        // Contours relative to sea level, so the shoreline
                        // always lands exactly on a line. Line width is
                        // normalised by the local gradient, keeping lines ~1px
                        // on flats and cliffs alike.
                        let grad = max((dzdx * dzdx + dzdy * dzdy).squareRoot(), 1e-4)
                        let rel = h - WATER_LEVEL
                        let minor = lineStrength(rel, interval, grad, 0.75)
                        let major = lineStrength(rel, interval * 5.0, grad, 1.35)
                        let sink = 1.0 - wet * 0.66
                        let glow = min((minor * 0.34 + major * 0.72) * sink, 1.3)
                        out += hue3 * glow
                    }

                    // Shoreline stroke, drawn where the WETNESS field crosses
                    // 0.5 rather than where raw height crosses sea level.
                    // Height is the wrong signal: marsh generates at ~27 m and
                    // oscillates across sea level, so a height test speckles
                    // the bog. Wetness already caps marsh below 0.5, so the
                    // interior never crosses while the coast always does.
                    let wl = wetness(hp[gi - 1], unord(bp[gi - 1]))
                    let wr = wetness(hp[gi + 1], unord(bp[gi + 1]))
                    let wu = wetness(hp[gi - hw], unord(bp[gi - hw]))
                    let wd = wetness(hp[gi + hw], unord(bp[gi + hw]))
                    let gwx = (wr - wl) * 0.5
                    let gwy = (wd - wu) * 0.5
                    let gw = max((gwx * gwx + gwy * gwy).squareRoot(), 1e-4)
                    let shore = 1.0 - smoothStepF(0.0, 1.4, abs(wet - 0.5) / gw)
                    out += SHORE * shore * 0.55

                    let g = grain(pxi, py)
                    let i = (py * n + pxi) * 4
                    px[i]     = UInt8(min(max(out.x + g, 0.0), 255.0))
                    px[i + 1] = UInt8(min(max(out.y + g, 0.0), 255.0))
                    px[i + 2] = UInt8(min(max(out.z + g, 0.0), 255.0))
                    px[i + 3] = 255
                }
            }
        }}}}
    }
}

/// Horizontal running-sum box blur over an RGB f32 field.
private func boxH(_ src: inout [Float], _ dst: inout [Float], _ w: Int, _ r: Int) {
    let n = Float(2 * r + 1)
    src.withUnsafeBufferPointer { s in
    dst.withUnsafeMutableBufferPointer { d in
        for y in 0..<w {
            let row = y * w
            var acc = SIMD3<Float>(repeating: 0)
            for x in 0...min(2 * r, w - 1) {
                acc += SIMD3(s[(row + x) * 3], s[(row + x) * 3 + 1], s[(row + x) * 3 + 2])
            }
            for x in r..<(w - r) {
                d[(row + x) * 3] = acc.x / n
                d[(row + x) * 3 + 1] = acc.y / n
                d[(row + x) * 3 + 2] = acc.z / n
                if x + r + 1 < w {
                    let a = (row + x + r + 1) * 3
                    let b = (row + x - r) * 3
                    acc += SIMD3(s[a], s[a + 1], s[a + 2]) - SIMD3(s[b], s[b + 1], s[b + 2])
                }
            }
        }
    }}
}

/// Vertical running-sum box blur over an RGB f32 field.
private func boxV(_ src: inout [Float], _ dst: inout [Float], _ w: Int, _ r: Int) {
    let n = Float(2 * r + 1)
    src.withUnsafeBufferPointer { s in
    dst.withUnsafeMutableBufferPointer { d in
        for x in 0..<w {
            var acc = SIMD3<Float>(repeating: 0)
            for y in 0...min(2 * r, w - 1) {
                let i = (y * w + x) * 3
                acc += SIMD3(s[i], s[i + 1], s[i + 2])
            }
            for y in r..<(w - r) {
                let o = (y * w + x) * 3
                d[o] = acc.x / n; d[o + 1] = acc.y / n; d[o + 2] = acc.z / n
                if y + r + 1 < w {
                    let a = ((y + r + 1) * w + x) * 3
                    let b = ((y - r) * w + x) * 3
                    acc += SIMD3(s[a], s[a + 1], s[a + 2]) - SIMD3(s[b], s[b + 1], s[b + 2])
                }
            }
        }
    }}
}

/// Faint dither so large flats don't band.
@inline(__always)
func grain(_ px: Int, _ py: Int) -> Float {
    var h = UInt32(truncatingIfNeeded: px) &* 0x9E37_79B9 ^ UInt32(truncatingIfNeeded: py) &* 0x85EB_CA6B
    h ^= h >> 15
    h = h &* 0xC2B2_AE35
    h ^= h >> 13
    return (Float(h & 0xFF) / 255.0 - 0.5) * 3.0
}

/// Contour interval landing roughly 12-20 px apart on screen, calibrated to
/// Valheim's gentle slopes rather than zoom alone.
func contourInterval(_ metersPerPx: Float) -> Float {
    let target = metersPerPx * 1.4
    let mag = powf(10.0, log10f(max(target, 1.0)).rounded(.down))
    let norm = target / mag
    let snapped: Float
    if norm < 1.5 { snapped = 1.0 }
    else if norm < 3.5 { snapped = 2.0 }
    else if norm < 7.5 { snapped = 5.0 }
    else { snapped = 10.0 }
    return max(snapped * mag, 2.0)
}

@inline(__always)
func lineStrength(_ h: Float, _ interval: Float, _ grad: Float, _ widthPx: Float) -> Float {
    let t = h / interval
    let f = t - t.rounded(.down)
    let distPx = min(f, 1.0 - f) * interval / grad
    return 1.0 - smoothStepF(0.0, widthPx, distPx)
}

@inline(__always)
func smoothStepF(_ lo: Float, _ hi: Float, _ x: Float) -> Float {
    let t = min(max((x - lo) / (hi - lo), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)
}

/// Dense 0..9 index for a biome, for histogram-shaped work.
public func ordOfBiome(_ b: Biome) -> UInt8 { ordOf(b) }
