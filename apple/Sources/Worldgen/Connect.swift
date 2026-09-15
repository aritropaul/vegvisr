//  Connect.swift
//  Landmass connectivity.
//
//  Players judge a seed by whether a boss is *on the same island as spawn*, not
//  by how far away it is — straight-line distance cannot answer that. So:
//  rasterise the world into land/water cells, label connected components, and
//  record which component each point falls in.

import Foundation

/// 32 m is half a zone: fine enough to resolve a river mouth or a narrow
/// isthmus, coarse enough that the whole world is ~390 k height samples. At
/// 64 m, separate islands routinely fuse across channels a player must swim.
public let CELL: Float = 32.0
public let GRID: Int = Int(2.0 * WORLD_SIZE / CELL)

/// How wide a water gap still counts as the same landmass, in cells.
///
/// This is the judgement call in this file. Pure land connectivity is the wrong
/// model: Valheim's rivers are 60-100 m wide and run everywhere, so strict
/// labelling splits every continent into fragments. Nobody describing a seed
/// counts a river as a barrier — "needs a boat" means open water you cannot
/// swim. Land is dilated by this radius before labelling, welding anything
/// under `2 * SWIM_GAP * CELL` = 128 m. Area is counted from the *undilated*
/// land so the reported size stays honest.
public let SWIM_GAP: Int = 2

@inline(__always) private func cellOf(_ w: Float) -> Int {
    Int(((w + WORLD_SIZE) / CELL).rounded(.down))
}
@inline(__always) private func centreOf(_ c: Int) -> Float {
    (Float(c) + 0.5) * CELL - WORLD_SIZE
}

public final class Landmass: @unchecked Sendable {
    /// Component id per cell, or -1 for water / outside the world disc.
    public let label: [Int32]
    /// Cell count per component.
    public let sizes: [UInt32]
    /// The component containing spawn, or -1.
    public private(set) var spawn: Int32 = -1

    init(label: [Int32], sizes: [UInt32]) {
        self.label = label
        self.sizes = sizes
        // Spawn is always at/near the origin; snap generously, because the
        // start temple sits on a meadow that can be one cell wide.
        self.spawn = nearestLand(0, 0, 24)
    }

    public func at(_ wx: Float, _ wy: Float) -> Int32 {
        let cx = cellOf(wx), cy = cellOf(wy)
        if cx < 0 || cy < 0 || cx >= GRID || cy >= GRID { return -1 }
        return label[cy * GRID + cx]
    }

    public func onSpawnLandmass(_ wx: Float, _ wy: Float) -> Bool {
        let l = at(wx, wy)
        return l >= 0 && l == spawn
    }

    public func areaKm2(_ l: Int32) -> Float {
        l < 0 ? 0 : Float(sizes[Int(l)]) * (CELL * CELL) / 1_000_000.0
    }

    /// A point on land near (wx, wy), searched outward in rings. A marker can
    /// land a few metres into a cell the coarse grid calls water; snapping
    /// avoids reporting a boss unreachable because of rasterisation.
    public func nearestLand(_ wx: Float, _ wy: Float, _ maxRings: Int) -> Int32 {
        let l = at(wx, wy)
        if l >= 0 { return l }
        let cx = cellOf(wx), cy = cellOf(wy)
        var r = 1
        while r <= maxRings {
            for dy in -r...r {
                for dx in -r...r {
                    // Only the ring itself, not its interior.
                    if abs(dx) != r && abs(dy) != r { continue }
                    let x = cx + dx, y = cy + dy
                    if x < 0 || y < 0 || x >= GRID || y >= GRID { continue }
                    let v = label[y * GRID + x]
                    if v >= 0 { return v }
                }
            }
            r += 1
        }
        return -1
    }
}

/// ~390 k height samples, which is the whole cost — the flood fill is linear
/// and trivial beside it.
public func buildLandmass(_ wg: WorldGenerator) -> Landmass {
    let n = GRID
    var land = [Bool](repeating: false, count: n * n)
    for cy in 0..<n {
        let wy = centreOf(cy)
        for cx in 0..<n {
            let wx = centreOf(cx)
            // Outside the playable disc is water by definition; skipping it
            // also avoids paying for height in the corners of the square.
            if (wx * wx + wy * wy).squareRoot() > WORLD_SIZE { continue }
            land[cy * n + cx] = wg.height(wx, wy) > WATER_LEVEL
        }
    }

    // Dilate by SWIM_GAP so short swims do not split a continent. A square
    // kernel is enough and separates into two cheap passes.
    var wide = [Bool](repeating: false, count: n * n)
    var row = [Bool](repeating: false, count: n * n)
    for y in 0..<n {
        for x in 0..<n {
            let lo = max(x - SWIM_GAP, 0), hi = min(x + SWIM_GAP, n - 1)
            var any = false
            for i in lo...hi where land[y * n + i] { any = true; break }
            row[y * n + x] = any
        }
    }
    for y in 0..<n {
        let lo = max(y - SWIM_GAP, 0), hi = min(y + SWIM_GAP, n - 1)
        for x in 0..<n {
            var any = false
            for j in lo...hi where row[j * n + x] { any = true; break }
            wide[y * n + x] = any
        }
    }

    // 4-connected flood fill. Deliberately not 8-connected: diagonal-only
    // contact is a corner touch, which welds landmasses meeting at a point.
    var label = [Int32](repeating: -1, count: n * n)
    var sizes: [UInt32] = []
    var stack: [Int] = []
    for start in 0..<(n * n) {
        if !wide[start] || label[start] >= 0 { continue }
        let id = Int32(sizes.count)
        var size: UInt32 = 0
        label[start] = id
        stack.append(start)
        while let i = stack.popLast() {
            // Only real land counts toward area; the dilation is scaffolding.
            if land[i] { size += 1 }
            let cx = i % n, cy = i / n
            if cx > 0 {
                let j = cy * n + (cx - 1)
                if wide[j] && label[j] < 0 { label[j] = id; stack.append(j) }
            }
            if cx + 1 < n {
                let j = cy * n + (cx + 1)
                if wide[j] && label[j] < 0 { label[j] = id; stack.append(j) }
            }
            if cy > 0 {
                let j = (cy - 1) * n + cx
                if wide[j] && label[j] < 0 { label[j] = id; stack.append(j) }
            }
            if cy + 1 < n {
                let j = (cy + 1) * n + cx
                if wide[j] && label[j] < 0 { label[j] = id; stack.append(j) }
            }
        }
        sizes.append(size)
    }
    // Cells that exist only because of the dilation are not land; clear them so
    // `at()` still answers "is this point on land" truthfully.
    for i in 0..<(n * n) where !land[i] { label[i] = -1 }

    return Landmass(label: label, sizes: sizes)
}
