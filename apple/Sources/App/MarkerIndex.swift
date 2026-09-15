//  MarkerIndex.swift
//  Uniform spatial hash over placed sites.
//
//  Hover fires at pointer-move rate and a world can hold ~12 000 sites, so a
//  linear scan is not viable — the web build measured 1.9 ms per move before it
//  bucketed. Cells are 512 m, which puts a handful of sites in each.

import Foundation
import Worldgen

struct MarkerIndex {
    static let cell: Float = 512

    private var buckets: [Int64: [Int]] = [:]
    private(set) var sites: [Site] = []

    init() {}

    init(_ sites: [Site]) {
        self.sites = sites
        for (i, s) in sites.enumerated() {
            buckets[Self.key(s.x, s.y), default: []].append(i)
        }
    }

    @inline(__always)
    private static func key(_ x: Float, _ y: Float) -> Int64 {
        let cx = Int64((x / cell).rounded(.down))
        let cy = Int64((y / cell).rounded(.down))
        return (cx &<< 32) ^ (cy & 0xFFFF_FFFF)
    }

    /// Nearest site within `radius` world metres, or nil. Only the buckets the
    /// radius can actually touch are visited.
    func hit(_ wx: Float, _ wy: Float, radius: Float) -> Site? {
        let c0 = Int64(((wx - radius) / Self.cell).rounded(.down))
        let c1 = Int64(((wx + radius) / Self.cell).rounded(.down))
        let r0 = Int64(((wy - radius) / Self.cell).rounded(.down))
        let r1 = Int64(((wy + radius) / Self.cell).rounded(.down))
        let r2 = radius * radius
        var best: Site?
        var bestD = Float.greatestFiniteMagnitude
        var cx = c0
        while cx <= c1 {
            var cy = r0
            while cy <= r1 {
                if let idx = buckets[(cx &<< 32) ^ (cy & 0xFFFF_FFFF)] {
                    for i in idx {
                        let s = sites[i]
                        let dx = s.x - wx, dy = s.y - wy
                        let d = dx * dx + dy * dy
                        if d < r2 && d < bestD { bestD = d; best = s }
                    }
                }
                cy += 1
            }
            cx += 1
        }
        return best
    }
}
