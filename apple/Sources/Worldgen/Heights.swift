//  Heights.swift
//  Per-biome height functions. Every one ends by calling addRivers, which is
//  why river pregeneration must complete before heights are meaningful.

import Foundation

extension WorldGenerator {
    /// Shared two-octave detail term used by most biomes.
    @inline(__always)
    func detail(_ wx: Float, _ wy: Float) -> Float {
        var n = perlin(wx * 0.01, wy * 0.01) * perlin(wx * 0.02, wy * 0.02)
        n += perlin(wx * 0.05, wy * 0.05) * perlin(wx * 0.1, wy * 0.1) * n * 0.5
        return n
    }

    /// Fine surface roughness appended by nearly every biome.
    @inline(__always)
    func roughness(_ wx: Float, _ wy: Float, _ h: Float) -> Float {
        h + perlin(wx * 0.1, wy * 0.1) * 0.01 + perlin(wx * 0.4, wy * 0.4) * 0.003
    }

    func meadowsHeight(_ wx0: Float, _ wy0: Float, _ base: Float) -> Float {
        let wx = wx0 + 100000.0 + offset3
        let wy = wy0 + 100000.0 + offset3
        let n = detail(wx, wy)
        var h = base + n * 0.1
        // Flatten meadows as they run up against mountain slopes.
        let over = h - 0.15
        let t = clamp01(base / 0.4)
        if over > 0.0 { h -= over * (1.0 - t) * 0.75 }
        h = addRivers(wx0, wy0, h)
        return roughness(wx, wy, h)
    }

    func forestHeight(_ wx0: Float, _ wy0: Float, _ base: Float) -> Float {
        var h = base
        let wx = wx0 + 100000.0 + offset3
        let wy = wy0 + 100000.0 + offset3
        h += detail(wx, wy) * 0.1
        h = addRivers(wx0, wy0, h)
        return roughness(wx, wy, h)
    }

    /// Plains shares Meadows' shape exactly.
    func plainsHeight(_ wx0: Float, _ wy0: Float, _ base: Float) -> Float {
        meadowsHeight(wx0, wy0, base)
    }

    /// Swamp is internally "Marsh": a near-flat sheet just above water level.
    /// Note it does NOT apply offset3.
    func marshHeight(_ wx0: Float, _ wy0: Float) -> Float {
        let wx = wx0 + 100000.0
        let wy = wy0 + 100000.0
        var h: Float = 0.137
        h += perlin(wx * 0.04, wy * 0.04) * perlin(wx * 0.08, wy * 0.08) * 0.03
        h = addRivers(wx0, wy0, h)
        return roughness(wx, wy, h)
    }

    /// Central-difference slope of the base height field.
    func baseHeightTilt(_ wx: Float, _ wy: Float) -> Float {
        let a = baseHeight(wx - 1.0, wy)
        let b = baseHeight(wx + 1.0, wy)
        let c = baseHeight(wx, wy - 1.0)
        let d = baseHeight(wx, wy + 1.0)
        return abs(b - a) + abs(c - d)
    }

    func snowMountainHeight(_ wx0: Float, _ wy0: Float, _ base: Float) -> Float {
        var h = base
        let tilt = baseHeightTilt(wx0, wy0)
        let wx = wx0 + 100000.0 + offset3
        let wy = wy0 + 100000.0 + offset3
        // Double the height above the mountain threshold.
        h += h - 0.4
        h += detail(wx, wy) * 0.2
        h = addRivers(wx0, wy0, h)
        h = roughness(wx, wy, h)
        return h + perlin(wx * 0.2, wy * 0.2) * 2.0 * tilt
    }

    func oceanHeight(_ wx: Float, _ wy: Float, _ base: Float) -> Float { base }

    func deepNorthHeight(_ wx0: Float, _ wy0: Float, _ base: Float) -> Float {
        var h = base
        let wx = wx0 + 100000.0 + offset3
        let wy = wy0 + 100000.0 + offset3
        h += max(h - 0.4, 0.0)
        h += detail(wx, wy) * 0.2
        h *= 1.2
        h = addRivers(wx0, wy0, h)
        h += perlin(wx * 0.1, wy * 0.1) * 0.01
        return h + perlin(wx * 0.4, wy * 0.4) * 0.003
    }

    func mistlandsHeight(_ wx0: Float, _ wy0: Float, _ base: Float) -> Float {
        var h = base
        let wx = wx0 + 100000.0 + offset3
        let wy = wy0 + 100000.0 + offset3
        var n = perlin(wx * 0.02 * 0.7, wy * 0.02 * 0.7) * perlin(wx * 0.04 * 0.7, wy * 0.04 * 0.7)
        n += perlin(wx * 0.03 * 0.7, wy * 0.03 * 0.7)
            * perlin(wx * 0.05 * 0.7, wy * 0.05 * 0.7) * n * 0.5
        if n > 0.0 { n = powf(n, 1.5) }
        h += n * 0.4
        h = addRivers(wx0, wy0, h)
        let t = clamp01(n * 7.0)
        h += perlin(wx * 0.1, wy * 0.1) * 0.03 * t
        h += perlin(wx * 0.4, wy * 0.4) * 0.01 * t
        let smooth = h + perlin(wx * 0.4, wy * 0.4) * 0.002
        // Quantise into the characteristic Mistlands terraces.
        let stepped = (h * 400.0).rounded(.up) / 400.0
        return lerp(smooth, stepped, t)
    }

    /// `GetAshlandsHeightPregenerate` — the cheap shape the game uses verbatim
    /// during river/stream placement.
    func ashlandsHeightPregenerate(_ wx0: Float, _ wy0: Float, _ base: Float) -> Float {
        var h = base
        let wx = wx0 + 100000.0 + offset3
        let wy = wy0 + 100000.0 + offset3
        h += detail(wx, wy) * 0.1
        h += 0.1
        h = roughness(wx, wy, h)
        return addRivers(wx0, wy0, h)
    }

    /// `GetAshlandsHeight` — turns the southern band into a crescent island
    /// with lava flats. Returns (height, lavaAlpha).
    func ashlandsHeight(_ wx0: Float, _ wy0: Float, _ base: Float, _ cheap: Bool) -> (Float, Float) {
        let x0 = Double(wx0)
        let y0 = Double(wy0)
        let a = Double(base)

        // Distance from the Ashlands arc. The arc used here is pulled 30% back
        // toward the world centre relative to the one is_ashlands classifies on.
        let ang = Double(worldAngle(wx0, wy0)) * 100.0
        let yo = Double(ASHLANDS_Y_OFFSET)
        let dy = y0 + yo - yo * 0.3
        let d = (x0 * x0 + dy * dy).squareRoot() - (Double(ASHLANDS_MIN_DISTANCE) + ang)
        var shore = 1.0 - clamp01F64(abs(d) / 1000.0)
        shore = mathfLikeSmoothStep(0.1, 1.0, shore)
        // Taper toward the east and west tips of the crescent.
        shore *= 1.0 - clamp01F64(abs(x0) / 7500.0)

        // Fade to open ocean approaching the world edge.
        let edge = 1.0 - clamp01F64((Double(length(wx0, wy0)) - 10150.0) / 600.0)

        let x = x0 + Double(Float(100000.0) + offset3)
        let y = y0 + Double(Float(100000.0) + offset3)

        // Broad cellular relief, smooth-stepped per octave before summing.
        var c = 0.0
        var amp = 1.0
        var freq = 0.33000001311302185
        for _ in 0..<(cheap ? 2 : 5) {
            c += amp * mathfLikeSmoothStep(0.0, 1.0, noise.cellular(x * freq, y * freq))
            freq *= 2.0
            amp *= 0.5
        }
        c = remap(c, -1.0, 1.0, 0.0, 1.0)
        let relief = lerpF64(shore, blendOverlay(shore, c), 0.5)

        var h = lerpF64(a, 0.15000000596046448, 0.75)
        h += relief * 0.5
        h = lerpF64(-1.0, h, mathfLikeSmoothStep(0.0, 1.0, edge))

        // Second, finer cellular field raised to the 4th power — the lava mask.
        let lavaFloor = 0.15
        var cell = 0.0
        var amp2 = 1.0
        var freq2 = 8.0
        for _ in 0..<(cheap ? 2 : 3) {
            cell += amp2 * noise.cellular(x * freq2, y * freq2)
            freq2 *= 2.0
            amp2 *= 0.5
        }
        cell = remap(cell, -1.0, 1.0, 0.0, 1.0)
        cell = clamp01F64(pow(cell, 4.0) * 2.0)

        var sx = noise.simplexFractal(x * 0.075, y * 0.075)
        sx = remap(sx, -1.0, 1.0, 0.0, 1.0)
        sx = pow(sx, 1.399999976158142)
        h *= sx

        var f = fbmF64(
            Float(x * 0.009999999776482582),
            Float(y * 0.009999999776482582),
            3, 2.0, 0.5
        )
        f *= clamp01F64(remap(shore, 0.0, 0.5, 0.5, 1.0))
        f = clamp01F64((f - 0.699999988079071) / (1.0 - 0.699999988079071))
        f = pow(f, 2.0)

        var lava = blendOverlay(f, cell)
        lava *= clamp01F64((h - lavaFloor - 0.02) / 0.01)

        // Carve the channels down by a noisy depth, floored just above the lava
        // surface so the molten sheet stays flat.
        var depth = pn(x * 0.05 + 5124.0, y * 0.05 + 5000.0)
        depth = pow(depth, 2.0)
        depth = remap(depth, 0.0, 1.0, 0.009999999776482582, 0.054999999701976776)
        let carved = Double(min(max(Float(h - depth),
                                     Float(lavaFloor + 0.009999999776482582)), 5000.0))
        h = lerpF64(h, carved, lava)

        return (Float(h), Float(lava))
    }

    public func biomeHeight(_ biome: Biome, _ wx: Float, _ wy: Float) -> Float {
        biomeHeightWithBase(biome, wx, wy, baseHeight(wx, wy))
    }

    /// `GetBiomeHeight` scales by the height multiplier *times both ocean gaps*.
    /// The gaps are 0 on the Ashlands and Deep North borders, which is what cuts
    /// both polar biomes off as islands. It multiplies the scale, not the
    /// height, so it also drowns terrain on the mainland side of the border.
    public func biomeHeightWithBase(_ biome: Biome, _ wx: Float, _ wy: Float, _ base: Float) -> Float {
        if length(wx, wy) > 10500.0 { return -2.0 * HEIGHT_MULTIPLIER }
        let mult = Float(Double(HEIGHT_MULTIPLIER)
            * createAshlandsGap(wx, wy)
            * createDeepNorthGap(wx, wy))
        return biomeHeightRaw(biome, wx, wy, base) * mult
    }

    func biomeHeightRaw(_ biome: Biome, _ wx: Float, _ wy: Float, _ base: Float) -> Float {
        switch biome {
        case .meadows:     return meadowsHeight(wx, wy, base)
        case .swamp:       return marshHeight(wx, wy)
        case .mountain:    return snowMountainHeight(wx, wy, base)
        case .blackForest: return forestHeight(wx, wy, base)
        case .plains:      return plainsHeight(wx, wy, base)
        case .deepNorth:   return deepNorthHeight(wx, wy, base)
        case .ashLands:    return ashlandsHeight(wx, wy, base, false).0
        case .ocean:       return oceanHeight(wx, wy, base)
        case .mistlands:   return mistlandsHeight(wx, wy, base)
        case .none:        return 0.0
        }
    }

    /// `GetPregenerationHeight` — used during stream placement, before the
    /// ocean gap is applied. Mistlands falls back to forest height here.
    public func pregenerationHeight(_ wx: Float, _ wy: Float) -> Float {
        if length(wx, wy) > 10500.0 { return -2.0 * HEIGHT_MULTIPLIER }
        let (b, base) = biomeWithBase(wx, wy)
        switch b {
        case .mistlands: return forestHeight(wx, wy, base) * HEIGHT_MULTIPLIER
        case .ashLands:  return ashlandsHeightPregenerate(wx, wy, base) * HEIGHT_MULTIPLIER
        default:         return biomeHeightRaw(b, wx, wy, base) * HEIGHT_MULTIPLIER
        }
    }

    /// Final world-space terrain height at a point.
    @inline(__always)
    public func height(_ wx: Float, _ wy: Float) -> Float {
        let (b, base) = biomeWithBase(wx, wy)
        return biomeHeightWithBase(b, wx, wy, base)
    }

    /// Combined sample. Computes the shared base height exactly once.
    @inline(__always)
    public func sample(_ wx: Float, _ wy: Float) -> (Biome, Float) {
        let (b, base) = biomeWithBase(wx, wy)
        return (b, biomeHeightWithBase(b, wx, wy, base))
    }

    /// Forest density field; `< 1.15` is "in forest".
    public func forestFactor(_ wx: Float, _ wy: Float) -> Float {
        fbmF32(wx * 0.01 * 0.4, wy * 0.01 * 0.4, 3, 1.6, 0.7)
    }

    /// Terrain roughness over a radius: 10 `Random.insideUnitCircle` probes
    /// drawn from the caller's stream — exactly 20 RNG values.
    public func terrainDelta(_ cx: Float, _ cy: Float, _ radius: Float,
                             _ rng: inout UnityRandom) -> Float {
        var hi: Float = -999999.0
        var lo: Float = 999999.0
        for _ in 0..<10 {
            let (ox, oy) = rng.insideUnitCircle()
            let h = height(cx + ox * radius, cy + oy * radius)
            if h < lo { lo = h }
            if h > hi { hi = h }
        }
        return hi - lo
    }
}

func fbmF32(_ x: Float, _ y: Float, _ octaves: Int32, _ lacunarity: Float, _ gain: Float) -> Float {
    var sum: Float = 0.0
    var amp: Float = 1.0
    var px = x, py = y
    for _ in 0..<octaves {
        sum += amp * perlin(px, py)
        amp *= gain
        px *= lacunarity
        py *= lacunarity
    }
    return sum
}
