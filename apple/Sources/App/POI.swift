//  POI.swift
//  Marker categories — colours and defaults mirror the web build's POI_KINDS.

import SwiftUI
import Worldgen

struct POICategory: Identifiable, Sendable {
    let kind: Kind
    let name: String
    let hex: UInt32
    let defaultOn: Bool
    let glyph: Glyph
    var id: UInt8 { kind.rawValue }
    var color: Color { Color(hex: hex) }
    var rgba: SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255,
              Float(hex & 0xFF) / 255, 1)
    }
}

/// Symbol per category, matching the web build's POI_KINDS table.
let POI_KINDS: [POICategory] = [
    .init(kind: .spawn,     name: "SPAWN",     hex: 0xFFFFFF, defaultOn: true,  glyph: .spawn),
    .init(kind: .boss,      name: "BOSS",      hex: 0xFF7A52, defaultOn: true,  glyph: .diamond),
    .init(kind: .trader,    name: "TRADER",    hex: 0xE8C07A, defaultOn: true,  glyph: .coin),
    .init(kind: .crypt,     name: "CRYPT",     hex: 0x9A7CFF, defaultOn: false, glyph: .arch),
    .init(kind: .camp,      name: "CAMP",      hex: 0xFF9AD5, defaultOn: false, glyph: .triangle),
    .init(kind: .cave,      name: "CAVE",      hex: 0x7FE3C4, defaultOn: false, glyph: .arch),
    .init(kind: .mine,      name: "MINE",      hex: 0x6FD0FF, defaultOn: false, glyph: .hex),
    .init(kind: .fortress,  name: "FORTRESS",  hex: 0xFFB03A, defaultOn: false, glyph: .keep),
    .init(kind: .runestone, name: "RUNESTONE", hex: 0xC9D4FF, defaultOn: false, glyph: .rune),
    .init(kind: .ruin,      name: "RUIN",      hex: 0x97A2AD, defaultOn: false, glyph: .ruin),
    .init(kind: .village,   name: "VILLAGE",   hex: 0xD6A06A, defaultOn: false, glyph: .house),
    .init(kind: .wreck,     name: "WRECK",     hex: 0x7AA6C2, defaultOn: false, glyph: .hull),
    .init(kind: .monument,  name: "MONUMENT",  hex: 0xB9A6E0, defaultOn: false, glyph: .menhir),
    .init(kind: .resource,  name: "RESOURCE",  hex: 0x8FD94A, defaultOn: false, glyph: .node),
    .init(kind: .mystery,   name: "MYSTERY",   hex: 0xFF5FA8, defaultOn: false, glyph: .sigil),
]

/// One placed site, flattened for the UI and the marker buffer.
struct Site: Sendable, Equatable, Identifiable {
    var id: String { "\(label)#\(Int(x)),\(Int(y))" }
    let kind: Kind
    let label: String
    let x: Float
    let y: Float
    let reachable: Bool
    var dist: Float { length(x, y) }
}

/// The headline facts for a seed: how big the starting landmass is, and for
/// every boss and trader whether you can walk there or need a boat.
struct SeedReport: Sendable {
    var spawnAreaKm2: Float = 0
    var largestKm2: Float = 0
    var landmasses: Int = 0
    var spawnIsLargest: Bool = false
    var reachable: Int = 0
    var total: Int = 0
    var sites: [Site] = []
}
