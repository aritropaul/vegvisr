//  Rivers.swift
//  Lakes, rivers and streams — Valheim's `Pregenerate()` pass.
//
//  Runs once per seed. Order is load-bearing: FindLakes -> PlaceRivers
//  (rendered into the point grid) -> PlaceStreams, because stream placement
//  samples terrain heights that already include the rivers carved above.

import Foundation

public struct RiverPoint {
    public var x: Float
    public var y: Float
    /// Radius.
    public var w: Float
    /// Radius squared, cached.
    public var w2: Float
}

public struct River {
    var p0: SIMD2<Float>
    var p1: SIMD2<Float>
    var widthMin: Float
    var widthMax: Float
    var curveWidth: Float
    var curveWavelength: Float
}

@inline(__always)
func riverGrid(_ wx: Float, _ wy: Float) -> Int64 {
    let i = Int64(((wx + 32.0) / 64.0).rounded(.down))
    let j = Int64(((wy + 32.0) / 64.0).rounded(.down))
    // Pack into one key; the grid is never iterated, only point-queried, so
    // packing cannot introduce order-dependent nondeterminism.
    return (i &<< 32) ^ (j & 0xFFFF_FFFF)
}

/// See WorldGenerator: written only during pregeneration, read-only after.
public final class Rivers: @unchecked Sendable {
    private var grid: [Int64: [RiverPoint]] = [:]

    public init() {}

    public var isEmpty: Bool { grid.isEmpty }

    /// Linear cone falloff; `weight` is the strongest single point, `width` is
    /// the falloff-weighted mean radius. Deliberately NOT a smoothstep.
    @inline(__always)
    public func weightAt(_ wx: Float, _ wy: Float) -> (Float, Float) {
        guard let points = grid[riverGrid(wx, wy)] else { return (0.0, 0.0) }
        var weight: Float = 0.0
        var accW: Float = 0.0
        var accT: Float = 0.0
        for rp in points {
            let dx = rp.x - wx
            let dy = rp.y - wy
            let d2 = dx * dx + dy * dy
            if d2 < rp.w2 {
                let t = 1.0 - d2.squareRoot() / rp.w
                if t > weight { weight = t }
                accW += rp.w * t
                accT += t
            }
        }
        let width = accT > 0.0 ? accW / accT : 0.0
        return (weight, width)
    }

    func addPoint(_ x: Float, _ y: Float, _ r: Float) {
        let homeI = Int32(((x + 32.0) / 64.0).rounded(.down))
        let homeJ = Int32(((y + 32.0) / 64.0).rounded(.down))
        let span = Int32((r / 64.0).rounded(.up))
        var i = homeJ - span
        while i <= homeJ + span {
            var j = homeI - span
            while j <= homeI + span {
                // InsideRiverGrid: inflate the footprint by half a cell.
                let cx = Float(j) * 64.0
                let cy = Float(i) * 64.0
                if abs(x - cx) < r + 32.0 && abs(y - cy) < r + 32.0 {
                    let key = (Int64(j) &<< 32) ^ (Int64(i) & 0xFFFF_FFFF)
                    grid[key, default: []].append(RiverPoint(x: x, y: y, w: r, w2: r * r))
                }
                j += 1
            }
            i += 1
        }
    }

    /// Rasterise river centrelines into the 64 m point grid. Each sample gets
    /// its own randomised radius, which gives the banks their wobble.
    func render(_ rivers: [River], _ rng: inout UnityRandom) {
        for river in rivers {
            let step = river.widthMin / 8.0
            let dx = river.p1.x - river.p0.x
            let dy = river.p1.y - river.p0.y
            let dist = length(dx, dy)
            if dist <= 0.0 || step <= 0.0 { continue }
            let nx = dx / dist
            let ny = dy / dist
            // Perpendicular.
            let px = -ny
            let py = nx

            var t: Float = 0.0
            while t <= dist {
                let a = t / river.curveWavelength
                // Triple-sine meander.
                let off = mathfSin(a) * mathfSin(a * 0.63411999) * mathfSin(a * 0.33412001) * river.curveWidth
                let r = rng.range(river.widthMin, river.widthMax)
                let x = river.p0.x + nx * t + px * off
                let y = river.p0.y + ny * t + py * off
                addPoint(x, y, r)
                t += step
            }
        }
    }
}

extension WorldGenerator {
    /// Height carving applied by every per-biome height function.
    @inline(__always)
    public func addRivers(_ wx: Float, _ wy: Float, _ h0: Float) -> Float {
        if rivers.isEmpty { return h0 }
        let (weight, width) = rivers.weightAt(wx, wy)
        if weight <= 0.0 { return h0 }
        let t = lerpStep(20.0, 60.0, width)
        let bed = lerp(0.14, 0.12, t)
        let bank = lerp(0.139, 0.128, t)
        var h = h0
        if h > bed { h = lerp(h, bed, weight) }
        if h > bank {
            let t2 = lerpStep(0.85, 1.0, weight)
            h = lerp(h, bank, t2)
        }
        return h
    }

    /// 128 m grid scan for sub-waterline terrain, then greedy cluster merge.
    public func findLakes() -> [SIMD2<Float>] {
        var pts: [SIMD2<Float>] = []
        var y: Float = -10000.0
        while y <= 10000.0 {
            var x: Float = -10000.0
            while x <= 10000.0 {
                if !(length(x, y) > 10000.0) && baseHeight(x, y) < 0.05 {
                    pts.append(SIMD2(x, y))
                }
                x += 128.0
            }
            y += 128.0
        }
        return mergePoints(pts, 800.0)
    }

    static func haveRiver(_ rivers: [River], _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
        rivers.contains { ($0.p0 == a && $0.p1 == b) || ($0.p0 == b && $0.p1 == a) }
    }

    static func haveRiverAt(_ rivers: [River], _ p: SIMD2<Float>) -> Bool {
        rivers.contains { $0.p0 == p || $0.p1 == p }
    }

    /// A river may not cross terrain above `heightLimit`, and must dip to water
    /// level somewhere along its length.
    func isRiverAllowed(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ step: Float, _ heightLimit: Float) -> Bool {
        let dist = length(p1.x - p0.x, p1.y - p0.y)
        if dist <= 0.0 { return false }
        let nx = (p1.x - p0.x) / dist
        let ny = (p1.y - p0.y) / dist
        var allAboveWater = true
        var t = step
        while t <= dist - step {
            let h = baseHeight(p0.x + nx * t, p0.y + ny * t)
            if h > heightLimit { return false }
            if h > 0.05 { allAboveWater = false }
            t += step
        }
        return !allAboveWater
    }

    func findRandomRiverEnd(_ rivers: [River], _ lakes: [SIMD2<Float>], _ p: SIMD2<Float>,
                            _ maxDistance: Float, _ heightLimit: Float, _ checkStep: Float,
                            _ rng: inout UnityRandom) -> Int32 {
        var candidates: [Int32] = []
        for (i, q) in lakes.enumerated() {
            if q != p
                && length(p.x - q.x, p.y - q.y) < maxDistance
                && !Self.haveRiver(rivers, p, q)
                && isRiverAllowed(p, q, checkStep, heightLimit) {
                candidates.append(Int32(i))
            }
        }
        if candidates.isEmpty { return -1 }
        return candidates[Int(rng.range(Int32(0), Int32(candidates.count)))]
    }

    func placeRivers(_ lakes: [SIMD2<Float>], _ rng: inout UnityRandom) -> [River] {
        var rivers: [River] = []
        var pending = lakes
        while pending.count > 1 {
            let p = pending[0]
            var idx = findRandomRiverEnd(rivers, lakes, p, 2000.0, 0.4, 128.0, &rng)
            if idx == -1 && !Self.haveRiverAt(rivers, p) {
                idx = findRandomRiverEnd(rivers, lakes, p, 5000.0, 0.4, 128.0, &rng)
            }
            if idx != -1 {
                let q = lakes[Int(idx)]
                let widthMax = rng.range(Float(60.0), Float(100.0))
                let widthMin = rng.range(Float(60.0), widthMax)
                let d = length(q.x - p.x, q.y - p.y)
                rivers.append(River(p0: p, p1: q, widthMin: widthMin, widthMax: widthMax,
                                    curveWidth: d / 15.0, curveWavelength: d / 20.0))
            } else {
                pending.removeFirst()
            }
        }
        return rivers
    }

    func findStreamStart(_ rng: inout UnityRandom) -> SIMD2<Float>? {
        for _ in 0..<100 {
            let x = rng.range(Float(-10000.0), Float(10000.0))
            let y = rng.range(Float(-10000.0), Float(10000.0))
            let h = pregenerationHeight(x, y)
            if h > 26.0 && h < 31.0 { return SIMD2(x, y) }
        }
        return nil
    }

    func findStreamEnd(_ start: SIMD2<Float>, _ rng: inout UnityRandom) -> SIMD2<Float>? {
        let iterations = 100
        let step = (Float(200.0) - 80.0) / Float(iterations)
        var len: Float = 200.0
        for _ in 0..<iterations {
            len -= step
            let f = rng.range(Float(0.0), Float.pi * 2.0)
            let x = start.x + mathfSin(f) * len
            let y = start.y + mathfCos(f) * len
            let h = pregenerationHeight(x, y)
            if h > 36.0 && h < 44.0 { return SIMD2(x, y) }
        }
        return nil
    }

    func placeStreams(_ rng: inout UnityRandom) -> [River] {
        var out: [River] = []
        for _ in 0..<3000 {
            guard let p = findStreamStart(&rng) else { continue }
            guard let q = findStreamEnd(p, &rng) else { continue }
            let cx = (p.x + q.x) * 0.5
            let cy = (p.y + q.y) * 0.5
            let ch = pregenerationHeight(cx, cy)
            if ch < 26.0 || ch > 44.0 { continue }
            let d = length(q.x - p.x, q.y - p.y)
            out.append(River(p0: p, p1: q, widthMin: 20.0, widthMax: 20.0,
                             curveWidth: d / 15.0, curveWavelength: d / 20.0))
        }
        return out
    }

    func pregenerate() {
        let lakes = findLakes()

        var riverRng = UnityRandom(seed: riverSeed)
        let rvs = placeRivers(lakes, &riverRng)
        rivers.render(rvs, &riverRng)

        // Streams sample terrain that already includes the rivers above.
        var streamRng = UnityRandom(seed: streamSeed)
        let streams = placeStreams(&streamRng)
        rivers.render(streams, &streamRng)
    }
}

/// Greedy cluster merge: repeatedly absorb the nearest remaining point within
/// `range`, averaging positions, until none is left in reach.
func mergePoints(_ input: [SIMD2<Float>], _ range: Float) -> [SIMD2<Float>] {
    var points = input
    var out: [SIMD2<Float>] = []
    while !points.isEmpty {
        var p = points.removeFirst()
        while true {
            var best: Int = -1
            var bestD: Float = 99999.0
            for (i, q) in points.enumerated() where q != p {
                let d = length(p.x - q.x, p.y - q.y)
                if d < range && d < bestD { best = i; bestD = d }
            }
            if best == -1 { break }
            p = SIMD2((p.x + points[best].x) * 0.5, (p.y + points[best].y) * 0.5)
            points[best] = points[points.count - 1]
            points.removeLast()
        }
        out.append(p)
    }
    return out
}

// MARK: - Cross-language parity diagnostics
extension Rivers {
    public var debugCellCount: Int { grid.count }
    public var debugPointCount: Int { grid.values.reduce(0) { $0 + $1.count } }
    /// Order-independent so the packed-key layout can't affect the result.
    public var debugChecksum: UInt64 {
        var acc: UInt64 = 0
        for (_, pts) in grid {
            for p in pts {
                acc = acc &+ UInt64(p.x.bitPattern) &* 0x9E3779B1
                    &+ UInt64(p.y.bitPattern) &* 0x85EBCA77
                    &+ UInt64(p.w.bitPattern)
            }
        }
        return acc
    }
}
