// Parity harness: prints the exact values the Rust suite asserts, so the Swift
// port can be diffed against it mechanically.
import Worldgen
import Foundation

func line(_ k: String, _ v: String) { print("\(k)\t\(v)") }

// --- RNG vectors (random.rs tests) ---
var r = UnityRandom(seed: 1234)
line("rng.state", "\(r.s0),\(r.s1),\(r.s2),\(r.s3)")
var outs: [UInt32] = []
for _ in 0..<5 { outs.append(r.nextU32()) }
line("rng.next5", outs.map(String.init).joined(separator: ","))

var r2 = UnityRandom(seed: 1234)
var ri: [Int32] = []
for _ in 0..<5 { ri.append(r2.range(Int32(0), Int32.max)) }
line("rng.range5", ri.map(String.init).joined(separator: ","))

// --- hash vectors ---
for s in ["Dedbtjdcv", "Valheim", "test", "a", ""] {
    line("hash.\(s.isEmpty ? "<empty>" : s)", "\(seedFromName(s))")
}
line("hash.Kh0zDpuPnw", "\(seedFromName("Kh0zDpuPnw"))")
line("hash.q6GhJN6FwT", "\(seedFromName("q6GhJN6FwT"))")

// --- world offsets, draw order ---
let wgA = WorldGenerator(seed: seedFromName("Dedbtjdcv"), worldGenVersion: 2, pregenerate: false)
line("offsets.Dedbtjdcv", "\(Int(wgA.offset0)),\(Int(wgA.offset1)),\(Int(wgA.offset2)),\(Int(wgA.offset3)),\(Int(wgA.offset4))")
line("seeds.Dedbtjdcv", "\(wgA.riverSeed),\(wgA.streamSeed)")

// --- Perlin ground truth sweep (same loop shape as tests/perlin.rs) ---
var maxAbs: Float = 0
var checksum: Double = 0
var yy: Float = -1.1
while yy <= 1.1 {
    var xx: Float = -1.1
    while xx <= 1.1 {
        let v = perlin(xx, yy)
        checksum += Double(v)
        maxAbs = max(maxAbs, abs(v))
        xx += 0.1
    }
    yy += 0.3
}
line("perlin.checksum", String(format: "%.9f", checksum))
line("perlin.mirror", "\(perlin(0.4,0.5) == perlin(-0.4,0.5) && perlin(0.4,0.5) == perlin(0.4,-0.5) && perlin(0.4,0.5) == perlin(-0.4,-0.5))")

// --- full world: biome + height samples on the test seed ---
let TEST = "j3QV2ftr3y"
line("seed.\(TEST)", "\(seedFromName(TEST))")
let t0 = Date()
let wg = WorldGenerator(seedName: TEST, worldGenVersion: 2)
line("pregenerate.ms", String(format: "%.1f", Date().timeIntervalSince(t0) * 1000))

for (x, y) in [(0,0), (500,500), (-1200,300), (3000,-2500), (0,-9800), (0,9800), (11000,0), (6000,6000)] {
    let (b, h) = wg.sample(Float(x), Float(y))
    line("sample.\(x),\(y)", "\(b.rawValue)\t\(String(format: "%.6f", h))")
}

// --- biome distribution over the 10km disc (matches bench.rs) ---
var counts = [Int](repeating: 0, count: 10)
let ordOf: [Biome: Int] = [.none:0, .meadows:1, .swamp:2, .mountain:3, .blackForest:4,
                            .plains:5, .ashLands:6, .deepNorth:7, .ocean:8, .mistlands:9]
let N = 384
var total = 0
for j in 0..<N {
    for i in 0..<N {
        let x = Float(-10000.0 + (Double(i) + 0.5) * 20000.0 / Double(N))
        let y = Float(10000.0 - (Double(j) + 0.5) * 20000.0 / Double(N))
        if length(x, y) > 10000.0 { continue }
        counts[ordOf[wg.biome(x, y)]!] += 1
        total += 1
    }
}
let names = ["None","Meadows","Swamp","Mountain","BlackForest","Plains","AshLands","DeepNorth","Ocean","Mistlands"]
for k in 0..<10 where counts[k] > 0 {
    line("dist.\(names[k])", String(format: "%.2f%%", 100.0 * Double(counts[k]) / Double(total)))
}

// --- tile rasterisation: byte-exact checksum of rendered pixels ---
let tr = TileRenderer(wg)
for (mode, pal, tag) in [(Mode.biome, Palette.classic, "biome/std"),
                          (Mode.terrain, Palette.classic, "terrain/std"),
                          (Mode.terrain, Palette.accessible, "terrain/a11y")] {
    let t = Date()
    tr.render(ox: -2000, oy: 2000, span: 4000, size: 256, mode: mode, palette: pal)
    let ms = Date().timeIntervalSince(t) * 1000
    var sum: UInt64 = 0
    var fnv: UInt64 = 0xcbf29ce484222325
    tr.withPixels { p in
        for b in p { sum &+= UInt64(b); fnv = (fnv ^ UInt64(b)) &* 0x100000001b3 }
    }
    line("tile.\(tag).sum", "\(sum)")
    line("tile.\(tag).fnv", String(format: "%016llx", fnv))
    line("tile.\(tag).ms", String(format: "%.1f", ms))
}

if ProcessInfo.processInfo.environment["DUMP"] != nil {
    tr.render(ox: -2000, oy: 2000, span: 4000, size: 256, mode: .biome, palette: .classic)
    tr.withPixels { p in
        FileManager.default.createFile(atPath: "/tmp/swift_tile.bin", contents: Data(p))
    }
}

// Exact bit patterns at the three pixels that disagreed.
for (wx, wy) in [(Float(-1734.375), Float(-125.0)), (Float(1906.25), Float(1250.0)), (Float(15.625), Float(-921.875))] {
    let (b, h) = wg.sample(wx, wy)
    line("bits.\(wx),\(wy)", "\(b.rawValue)\t\(String(format: "%08x", h.bitPattern))")
}

// --- location placement: count, per-kind tally, and a position checksum ---
let tLoc = Date()
let placed = generateLocations(wg)
line("loc.ms", String(format: "%.0f", Date().timeIntervalSince(tLoc) * 1000))
line("loc.count", "\(placed.count)")
var kindCounts = [Int](repeating: 0, count: 15)
var chk: UInt64 = 0
for p in placed {
    kindCounts[Int(LOCATIONS[p.cfg].kind.rawValue)] += 1
    chk = chk &+ UInt64(p.x.bitPattern) &* 0x9E3779B1
        &+ UInt64(p.y.bitPattern) &* 0x85EBCA77 &+ UInt64(p.cfg)
}
line("loc.kinds", kindCounts.map(String.init).joined(separator: ","))
line("loc.checksum", String(format: "%016llx", chk))
// Bosses and traders, in placement order, exact coordinates.
for p in placed where LOCATIONS[p.cfg].kind == .boss || LOCATIONS[p.cfg].kind == .spawn {
    line("loc.site.\(LOCATIONS[p.cfg].label)", "\(Int(p.x)),\(Int(p.y))")
}
