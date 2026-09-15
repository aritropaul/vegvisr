//  Geo.swift
//  Port of Valheim's `WorldGenerator` terrain + biome classification.
//  Follows the porting contract in UnityRandom.swift.

import Foundation

public let WORLD_SIZE: Float = 10000.0
public let WATER_EDGE: Float = 10500.0
public let HEIGHT_MULTIPLIER: Float = 200.0
public let ASHLANDS_MIN_DISTANCE: Float = 12000.0
public let ASHLANDS_Y_OFFSET: Float = -4000.0
public let DEEP_NORTH_MIN_DISTANCE: Float = 12000.0
public let DEEP_NORTH_Y_OFFSET: Float = 4000.0
/// Radii outside which the polar ocean gaps are provably 1.0.
private let GAP_INNER: Float = 11400.0
private let GAP_OUTER: Float = 12600.0
/// Sea level in world Y units.
public let WATER_LEVEL: Float = 30.0

public enum Biome: UInt16, Sendable, CaseIterable {
    case none = 0
    case meadows = 1
    case swamp = 2
    case mountain = 4
    case blackForest = 8
    case plains = 16
    case ashLands = 32
    case deepNorth = 64
    case ocean = 256
    case mistlands = 512
}

/// `DUtils.Length` squares and sums in double before the sqrt. In f32 the sum
/// reaches ~2e8 at world-edge distances where the representable step is ~16,
/// enough to land on the wrong side of the biome-radius comparisons.
@inline(__always)
public func length(_ x: Float, _ y: Float) -> Float {
    Float((Double(x) * Double(x) + Double(y) * Double(y)).squareRoot())
}

/// `DUtils.Lerp`. Clamps at both ends and interpolates as `a*(1-t) + b*t` in
/// double rather than `a + (b-a)*t`. The two forms disagree in the last bits.
@inline(__always)
public func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    if t <= 0.0 { return a }
    if t >= 1.0 { return b }
    return Float(Double(a) * (1.0 - Double(t)) + Double(b) * Double(t))
}

@inline(__always)
public func lerpF64(_ a: Double, _ b: Double, _ t: Double) -> Double {
    if t <= 0.0 { return a }
    if t >= 1.0 { return b }
    return a * (1.0 - t) + b * t
}

/// `DUtils.Fbm` — the double overload.
@inline(__always)
public func fbmF64(_ px: Float, _ py: Float, _ octaves: Int32, _ lacunarity: Double, _ gain: Double) -> Double {
    var sum = 0.0
    var amp = 1.0
    var x = Double(px)
    var y = Double(py)
    for _ in 0..<octaves {
        sum += amp * pn(x, y)
        amp *= gain
        x *= lacunarity
        y *= lacunarity
    }
    return sum
}

@inline(__always)
public func clamp01(_ v: Float) -> Float { v > 1.0 ? 1.0 : (v < 0.0 ? 0.0 : v) }

@inline(__always)
public func lerpStep(_ l: Float, _ h: Float, _ v: Float) -> Float { clamp01((v - l) / (h - l)) }

@inline(__always)
public func smoothStep(_ lo: Float, _ hi: Float, _ x: Float) -> Float {
    let t = Double(clamp01(Float((Double(x) - Double(lo)) / (Double(hi) - Double(lo)))))
    return Float(t * t * (3.0 - 2.0 * t))
}

@inline(__always)
public func clamp01F64(_ v: Double) -> Double { v > 1.0 ? 1.0 : (v < 0.0 ? 0.0 : v) }

/// `DUtils.MathfLikeSmoothStep`. The game narrows to f32 before widening back
/// to f64 on return; that rounding is load-bearing for the ocean-gap edge.
@inline(__always)
public func mathfLikeSmoothStep(_ from: Double, _ to: Double, _ t0: Double) -> Double {
    let t = clamp01F64(t0)
    let s = -2.0 * t * t * t + 3.0 * t * t
    return Double(Float(to * s + from * (1.0 - s)))
}

@inline(__always)
public func blendOverlay(_ a: Double, _ b: Double) -> Double {
    a < 0.5 ? 2.0 * a * b : 1.0 - 2.0 * (1.0 - a) * (1.0 - b)
}

@inline(__always)
public func remap(_ value: Double, _ inLo: Double, _ inHi: Double, _ outLo: Double, _ outHi: Double) -> Double {
    let t = inLo == inHi ? 0.0 : clamp01F64((value - inLo) / (inHi - inLo))
    return outLo + (outHi - outLo) * t
}

/// Immutable once `init` returns: every stored property is `let`, and the one
/// reference field (`rivers`) is only written during pregeneration inside that
/// init. Sharing a finished generator across tasks is therefore safe, which the
/// compiler cannot see on its own.
public final class WorldGenerator: @unchecked Sendable {
    public let seed: Int32
    public let offset0: Float
    public let offset1: Float
    public let offset2: Float
    public let offset3: Float
    public let offset4: Float
    public let riverSeed: Int32
    public let streamSeed: Int32

    // VersionSetup(): tunables that differ for legacy worlds.
    let minMountainDistance: Float
    let maxMarshDistance: Float
    let minDarklandNoise: Float

    public var rivers = Rivers()
    /// Seeded **0, not the world seed** — the game constructs it with the world
    /// seed then immediately calls SetSeed(0), so the argument never survives.
    public let noise = FastNoise(seed: 0)

    public convenience init(seedName: String, worldGenVersion: Int32) {
        self.init(seed: seedFromName(seedName), worldGenVersion: worldGenVersion, pregenerate: true)
    }

    /// Offsets drawn but **no river/lake/stream pregeneration**. Biome
    /// classification never reads river data, so seed search can screen on
    /// biomes alone. Heights from this instance are wrong wherever water carved.
    public convenience init(biomeOnly seed: Int32, worldGenVersion: Int32) {
        self.init(seed: seed, worldGenVersion: worldGenVersion, pregenerate: false)
    }

    public init(seed: Int32, worldGenVersion: Int32, pregenerate doPregen: Bool) {
        // VersionSetup(version)
        var minMountain: Float = 1000.0
        var maxMarsh: Float = 6000.0
        var minDarkland: Float = 0.4
        if worldGenVersion <= 0 { minMountain = 1500.0 }
        if worldGenVersion <= 1 { minDarkland = 0.5; maxMarsh = 8000.0 }
        minMountainDistance = minMountain
        maxMarshDistance = maxMarsh
        minDarklandNoise = minDarkland

        // Draw order is load-bearing: offset0..3, riverSeed, streamSeed, then
        // offset4 LAST. Getting this wrong silently produces a different world.
        var r = UnityRandom(seed: seed)
        self.seed = seed
        offset0 = Float(r.range(Int32(-10000), Int32(10000)))
        offset1 = Float(r.range(Int32(-10000), Int32(10000)))
        offset2 = Float(r.range(Int32(-10000), Int32(10000)))
        offset3 = Float(r.range(Int32(-10000), Int32(10000)))
        riverSeed = r.range(Int32.min, Int32.max)
        streamSeed = r.range(Int32.min, Int32.max)
        offset4 = Float(r.range(Int32(-10000), Int32(10000)))

        if doPregen { pregenerate() }
    }

    /// NOTE: atan2(x, y), not the conventional atan2(y, x).
    @inline(__always)
    public func worldAngle(_ wx: Float, _ wy: Float) -> Float {
        mathfSin(mathfAtan2(wx, wy) * 20.0)
    }

    /// `GetBaseHeight`. The one generator function that keeps its coordinate
    /// accumulation in **double** all the way to the noise call. Running it in
    /// f32 throughout flips roughly one pixel in 400 000 across the
    /// ocean/mountain thresholds, and those flips land on coastlines.
    public func baseHeight(_ wxIn: Float, _ wyIn: Float) -> Float {
        let dist = length(wxIn, wyIn)
        let x = Double(wxIn) + 100000.0 + Double(offset0)
        let y = Double(wyIn) + 100000.0 + Double(offset1)

        // The f32 constants the game uses, written at the width the
        // double-precision path actually sees them.
        let A = 0.0020000000949949026
        let B = 0.003000000026077032
        let C = 0.004999999888241291
        let D = 0.009999999776482582

        var h: Float = 0.0
        h = Float(Double(h) + pn(x * A * 0.5, y * A * 0.5) * pn(x * B * 0.5, y * B * 0.5))
        h = Float(Double(h) + pn(x * A, y * A) * pn(x * B, y * B) * Double(h) * 0.8999999761581421)
        h = Float(Double(h) + pn(x * C, y * C) * pn(x * D, y * D) * 0.5 * Double(h))
        h = Float(Double(h) - 0.07000000029802322)

        // Flattening mask: carves broad lowland plateaus away from the centre.
        let n4 = pn(x * A * 0.25 + 0.12300000339746475, y * A * 0.25 + 0.15123000741004944)
        let n5 = pn(x * A * 0.25 + 0.32100000977516174, y * A * 0.25 + 0.23100000619888306)
        let v = abs(Float(n4 - n5))
        var mask = 1.0 - Double(lerpStep(0.02, 0.12, v))
        mask *= Double(smoothStep(744.0, 1000.0, dist))
        h = Float(Double(h) * (1.0 - mask))

        // World edge falloff.
        if dist > WORLD_SIZE {
            let t = lerpStep(WORLD_SIZE, WATER_EDGE, dist)
            h = lerp(h, -0.2, t)
            let EDGE: Float = 10490.0
            if dist > EDGE {
                let t2 = lerpStep(EDGE, WATER_EDGE, dist)
                h = lerp(h, -2.0, t2)
            }
            return h
        }

        // Keep big mountains away from spawn.
        if dist < minMountainDistance && h > 0.28 {
            let t3 = clamp01(Float((Double(h) - 0.2800000011920929) / 0.09999999403953552))
            h = lerp(
                lerp(0.28, 0.38, t3),
                h,
                lerpStep(minMountainDistance - 400.0, minMountainDistance, dist)
            )
        }
        return h
    }

    /// `CreateAshlandsGap` — a multiplier on the height scale. Reaches 0 exactly
    /// on the Ashlands boundary and returns to 1 over 400 m either side.
    @inline(__always)
    public func createAshlandsGap(_ wx: Float, _ wy: Float) -> Double {
        let r = length(wx, wy + ASHLANDS_Y_OFFSET)
        if r < GAP_INNER || r > GAP_OUTER { return 1.0 }
        let a = Double(worldAngle(wx, wy)) * 100.0
        let v = Double(r) - (Double(ASHLANDS_MIN_DISTANCE) + a)
        let c = Float(clamp01F64(abs(v) / 400.0))
        return mathfLikeSmoothStep(0.0, 1.0, Double(c))
    }

    /// `CreateDeepNorthGap` — the same mechanism at the north pole.
    @inline(__always)
    public func createDeepNorthGap(_ wx: Float, _ wy: Float) -> Double {
        let r = length(wx, wy + DEEP_NORTH_Y_OFFSET)
        if r < GAP_INNER || r > GAP_OUTER { return 1.0 }
        let a = Double(worldAngle(wx, wy)) * 100.0
        let v = Double(r) - (Double(DEEP_NORTH_MIN_DISTANCE) + a)
        let c = Float(clamp01F64(abs(v) / 400.0))
        return mathfLikeSmoothStep(0.0, 1.0, Double(c))
    }

    @inline(__always)
    public func biome(_ wx: Float, _ wy: Float) -> Biome { biomeWithBase(wx, wy).0 }

    /// Returns the biome alongside the base height it was derived from, so
    /// callers that also need terrain height don't pay for it twice.
    public func biomeWithBase(_ wx: Float, _ wy: Float) -> (Biome, Float) {
        let dist = length(wx, wy)
        let base = baseHeight(wx, wy)
        let a = worldAngle(wx, wy) * 100.0

        if length(wx, wy + -4000.0) > 12000.0 + a { return (.ashLands, base) }
        if base <= 0.02 { return (.ocean, base) }
        if length(wx, wy + 4000.0) > 12000.0 + a {
            return base > 0.4 ? (.mountain, base) : (.deepNorth, base)
        }
        if base > 0.4 { return (.mountain, base) }
        if perlin((offset0 + wx) * 0.001, (offset0 + wy) * 0.001) > 0.6
            && dist > 2000.0 && dist < maxMarshDistance
            && base > 0.05 && base < 0.25 {
            return (.swamp, base)
        }
        if perlin((offset4 + wx) * 0.001, (offset4 + wy) * 0.001) > minDarklandNoise
            && dist > 6000.0 + a && dist < 10000.0 {
            return (.mistlands, base)
        }
        if perlin((offset1 + wx) * 0.001, (offset1 + wy) * 0.001) > 0.4
            && dist > 3000.0 + a && dist < 8000.0 {
            return (.plains, base)
        }
        if perlin((offset2 + wx) * 0.001, (offset2 + wy) * 0.001) > 0.4
            && dist > 600.0 + a && dist < 6000.0 {
            return (.blackForest, base)
        }
        if dist > 5000.0 + a { return (.blackForest, base) }
        return (.meadows, base)
    }
}
