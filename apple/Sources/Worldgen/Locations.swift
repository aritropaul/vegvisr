//  Locations.swift
//  Port of Valheim's `ZoneSystem.GenerateLocations`.
//
//  Two things make this harder than it looks:
//    * The RNG draw order is load-bearing. `terrainDelta` alone consumes 20
//      values (10 insideUnitCircle calls, 2 draws each) and is only reached
//      when the cheaper checks above it pass. Reorder the checks and every
//      position downstream changes.
//    * Locations cannot be generated independently. There is one shared
//      occupancy map — one location per 64 m zone, globally, across all types —
//      and prioritised types are placed first, so a boss altar can block a crypt.

import Foundation

public let ZONE_SIZE: Float = 64.0
private let WATER_LEVEL_LOC: Float = 30.0

public enum Kind: UInt8, Sendable, CaseIterable {
    case spawn = 0, boss = 1, trader = 2, crypt = 3, camp = 4, cave = 5, mine = 6
    case fortress = 7, runestone = 8, ruin = 9, village = 10, wreck = 11
    case monument = 12, resource = 13, mystery = 14
}

public struct LocationConfig: Sendable {
    public let prefab: String
    public let label: String
    public let kind: Kind
    /// Heightmap.Biome bitmask.
    public let biome: UInt16
    /// 1 = Edge, 2 = Median, 3 = Everything.
    public let biomeArea: UInt8
    public let quantity: Int32
    public let prioritized: Bool
    public let centerFirst: Bool
    public let unique: Bool
    public let minDistance: Float
    public let maxDistance: Float
    public let minAltitude: Float
    public let maxAltitude: Float
    public let inForest: Bool
    public let forestMin: Float
    public let forestMax: Float
    public let exteriorRadius: Float
    public let minTerrainDelta: Float
    public let maxTerrainDelta: Float
    public let minDistanceFromSimilar: Float
    public let group: String
}

// Biome bitmask shorthands, matching the Rust table's own constants.
private let M: UInt16 = 1
private let SW: UInt16 = 2
private let MT: UInt16 = 4
private let BF: UInt16 = 8
private let PL: UInt16 = 16
private let AL: UInt16 = 32
private let ML: UInt16 = 512
private let DN: UInt16 = 64
private let OC: UInt16 = 256

/// 183 entries, transpiled straight from locations.rs rather than
/// retyped — the web build's own notes call this table the error-prone half.
public let LOCATIONS: [LocationConfig] = [
    .init(prefab: "StartTemple", label: "Sacrificial Stones", kind: .spawn, biome: M, biomeArea: 2, quantity: 1, prioritized: true, centerFirst: true, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 3.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 25.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Eikthyrnir", label: "Eikthyr", kind: .boss, biome: M, biomeArea: 2, quantity: 3, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Dragonqueen", label: "Moder", kind: .boss, biome: MT, biomeArea: 2, quantity: 3, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 150.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 3000.0, group: ""),
    .init(prefab: "Hildir_cave", label: "Howling Caverns", kind: .ruin, biome: MT, biomeArea: 2, quantity: 3, prioritized: true, centerFirst: false, unique: false, minDistance: 1000.0, maxDistance: 0.0, minAltitude: 200.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 15.00, minTerrainDelta: 0.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 2000.0, group: ""),
    .init(prefab: "Hildir_crypt", label: "Smouldering Tombs", kind: .crypt, biome: BF, biomeArea: 2, quantity: 3, prioritized: true, centerFirst: false, unique: false, minDistance: 3000.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 18.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 3000.0, group: ""),
    .init(prefab: "Hildir_plainsfortress", label: "Sealed Tower", kind: .ruin, biome: PL, biomeArea: 2, quantity: 3, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 8.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 3000.0, group: ""),
    .init(prefab: "GoblinKing", label: "Yagluth", kind: .boss, biome: PL, biomeArea: 2, quantity: 4, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 3000.0, group: ""),
    .init(prefab: "GDKing", label: "The Elder", kind: .boss, biome: BF, biomeArea: 2, quantity: 4, prioritized: true, centerFirst: false, unique: false, minDistance: 1000.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 25.00, minTerrainDelta: 0.0, maxTerrainDelta: 5.0, minDistanceFromSimilar: 3000.0, group: ""),
    .init(prefab: "Bonemass", label: "Bonemass", kind: .boss, biome: SW, biomeArea: 2, quantity: 5, prioritized: true, centerFirst: false, unique: false, minDistance: 2000.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 19.79, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 3000.0, group: ""),
    .init(prefab: "Vendor_BlackForest", label: "Haldor", kind: .trader, biome: BF, biomeArea: 2, quantity: 10, prioritized: true, centerFirst: false, unique: true, minDistance: 1500.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 512.0, group: ""),
    .init(prefab: "Hildir_camp", label: "Hildir", kind: .trader, biome: M, biomeArea: 3, quantity: 10, prioritized: true, centerFirst: false, unique: true, minDistance: 3000.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 1000.0, group: ""),
    .init(prefab: "BogWitch_Camp", label: "Bog Witch", kind: .trader, biome: SW, biomeArea: 2, quantity: 10, prioritized: true, centerFirst: false, unique: true, minDistance: 3000.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 1000.0, group: ""),
    .init(prefab: "AncientUpgradeStation", label: "Ancient Upgrade Station", kind: .mystery, biome: MT, biomeArea: 2, quantity: 10, prioritized: true, centerFirst: false, unique: true, minDistance: 200.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 22.00, minTerrainDelta: 0.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 400.0, group: "AncientUpgradeStation"),
    .init(prefab: "DN_Bossroom", label: "Fimbulbringer", kind: .boss, biome: DN, biomeArea: 3, quantity: 3, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 80.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 6.0, minDistanceFromSimilar: 1024.0, group: "dn_boss"),
    .init(prefab: "Mistlands_DvergrBossEntrance1", label: "The Queen", kind: .boss, biome: ML, biomeArea: 2, quantity: 5, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 2048.0, group: "DvergrBoss"),
    .init(prefab: "Mistlands_DvergrTownEntrance1", label: "Infested Mine", kind: .mine, biome: ML, biomeArea: 2, quantity: 120, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 12.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 5.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 256.0, group: "DvergrDungeon"),
    .init(prefab: "Mistlands_DvergrTownEntrance2", label: "Infested Mine", kind: .mine, biome: ML, biomeArea: 2, quantity: 120, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 256.0, group: "DvergrDungeon"),
    .init(prefab: "FaderLocation", label: "Fader", kind: .boss, biome: AL, biomeArea: 2, quantity: 3, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 2048.0, group: "FaderBoss"),
    .init(prefab: "CharredFortress", label: "Charred Fortress", kind: .fortress, biome: AL, biomeArea: 3, quantity: 20, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 20.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 256.0, group: "FaderBoss"),
    .init(prefab: "PlaceofMystery1", label: "Placeof Mystery", kind: .mystery, biome: AL, biomeArea: 2, quantity: 1, prioritized: true, centerFirst: false, unique: true, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 5.0, minDistanceFromSimilar: 2048.0, group: "PlaceofMystery"),
    .init(prefab: "PlaceofMystery2", label: "Placeof Mystery", kind: .mystery, biome: AL, biomeArea: 2, quantity: 1, prioritized: true, centerFirst: false, unique: true, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 5.0, minDistanceFromSimilar: 2048.0, group: "PlaceofMystery"),
    .init(prefab: "PlaceofMystery3", label: "Placeof Mystery", kind: .mystery, biome: AL, biomeArea: 2, quantity: 1, prioritized: true, centerFirst: false, unique: true, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 5.0, minDistanceFromSimilar: 2048.0, group: "PlaceofMystery"),
    .init(prefab: "SunkenCrypt4", label: "Sunken Crypt", kind: .crypt, biome: SW, biomeArea: 2, quantity: 175, prioritized: true, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 64.0, group: "SunkenCrypt"),
    .init(prefab: "CombatRuin01", label: "Combat Ruin", kind: .ruin, biome: M, biomeArea: 3, quantity: 5, prioritized: false, centerFirst: false, unique: false, minDistance: 1500.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 13.00, minTerrainDelta: 0.0, maxTerrainDelta: 1.5, minDistanceFromSimilar: 2000.0, group: ""),
    .init(prefab: "GoblinCamp2_1", label: "Goblin Camp", kind: .camp, biome: PL, biomeArea: 3, quantity: 5, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 30.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "BigRockClearing", label: "Big Rock Clearing", kind: .mystery, biome: BF, biomeArea: 2, quantity: 10, prioritized: false, centerFirst: false, unique: true, minDistance: 1000.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 15.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 2000.0, group: ""),
    .init(prefab: "StoneTowerRuins05_leet", label: "Stone Tower Ruins", kind: .ruin, biome: MT, biomeArea: 3, quantity: 10, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 150.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 22.00, minTerrainDelta: 0.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 32.0, group: ""),
    .init(prefab: "WoodHouse1", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse2", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse3", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse4", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse5", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse6", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse7", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse8", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse9", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse10", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse11", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse12", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 6.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "WoodHouse13", label: "Wood House", kind: .village, biome: M, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 9.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "GoblinHut03", label: "Goblin Hut", kind: .camp, biome: PL, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "TarPit2_1", label: "Tar Pit", kind: .resource, biome: PL, biomeArea: 2, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 3.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 25.00, minTerrainDelta: 0.0, maxTerrainDelta: 1.5, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "StoneCircle", label: "Stone Circle", kind: .monument, biome: M, biomeArea: 3, quantity: 25, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 16.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 200.0, group: ""),
    .init(prefab: "SwampWell1", label: "Swamp Well", kind: .resource, biome: SW, biomeArea: 3, quantity: 25, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 1024.0, group: ""),
    .init(prefab: "MountainWell1", label: "Mountain Well", kind: .resource, biome: MT, biomeArea: 3, quantity: 25, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 14.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 256.0, group: ""),
    .init(prefab: "CharredTowerRuins3", label: "Charred Tower Ruins", kind: .ruin, biome: AL, biomeArea: 3, quantity: 30, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 500.0, group: ""),
    .init(prefab: "DN_gammeltrollFrac01", label: "Gammeltroll Frac", kind: .ruin, biome: DN, biomeArea: 3, quantity: 30, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "DN_gammeltrollFrac02", label: "Gammeltroll Frac", kind: .ruin, biome: DN, biomeArea: 3, quantity: 30, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 10.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "GoblinHut01", label: "Goblin Hut", kind: .camp, biome: PL, biomeArea: 3, quantity: 30, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 6.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "GoblinHut02", label: "Goblin Hut", kind: .camp, biome: PL, biomeArea: 3, quantity: 30, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 7.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "CharredTowerRuins2", label: "Charred Tower Ruins", kind: .ruin, biome: AL, biomeArea: 3, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "TheHole01", label: "The Hole", kind: .cave, biome: DN, biomeArea: 2, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 28.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 256.0, group: ""),
    .init(prefab: "Dolmen03", label: "Dolmen", kind: .monument, biome: M|BF, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Waymarker01", label: "Waymarker", kind: .monument, biome: MT, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 3.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Waymarker02", label: "Waymarker", kind: .monument, biome: MT, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 3.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "BearCave", label: "Bear Cave", kind: .cave, biome: BF, biomeArea: 2, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 12.00, minTerrainDelta: 5.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 256.0, group: ""),
    .init(prefab: "SwampHut1_1", label: "Swamp Hut", kind: .village, biome: SW, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "SwampHut2_1", label: "Swamp Hut", kind: .village, biome: SW, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "SwampHut3_1", label: "Swamp Hut", kind: .village, biome: SW, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "TarPit1_1", label: "Tar Pit", kind: .resource, biome: PL, biomeArea: 2, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 3.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 0.0, maxTerrainDelta: 1.5, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Dolmen01", label: "Dolmen", kind: .monument, biome: M|BF, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Dolmen02", label: "Dolmen", kind: .monument, biome: M|BF, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "ShipSetting01", label: "Ship Setting", kind: .monument, biome: M, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: ""),
    .init(prefab: "MountainGrave01", label: "Mountain Grave", kind: .monument, biome: MT, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 3.93, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 50.0, group: ""),
    .init(prefab: "FortressRuins", label: "Fortress Ruins", kind: .fortress, biome: AL, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "LeviathanLava", label: "Lava Leviathan", kind: .ruin, biome: AL, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 10.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "SulfurArch", label: "Sulfur Arch", kind: .monument, biome: AL, biomeArea: 2, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 10.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 30.00, minTerrainDelta: 0.0, maxTerrainDelta: 6.0, minDistanceFromSimilar: 40.0, group: ""),
    .init(prefab: "AshlandRuins", label: "Ashland Ruins", kind: .ruin, biome: AL, biomeArea: 2, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 16.0, group: ""),
    .init(prefab: "CharredRuins2", label: "Charred Ruins", kind: .ruin, biome: AL, biomeArea: 2, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -5.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 15.00, minTerrainDelta: 0.0, maxTerrainDelta: 30.0, minDistanceFromSimilar: 128.0, group: ""),
    .init(prefab: "CharredRuins3", label: "Charred Ruins", kind: .ruin, biome: AL, biomeArea: 2, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -5.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 30.0, minDistanceFromSimilar: 128.0, group: ""),
    .init(prefab: "CharredRuins4", label: "Charred Ruins", kind: .ruin, biome: AL, biomeArea: 2, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -5.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 30.0, minDistanceFromSimilar: 128.0, group: ""),
    .init(prefab: "TarPit3_1", label: "Tar Pit", kind: .resource, biome: PL, biomeArea: 2, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 3.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 14.00, minTerrainDelta: 0.0, maxTerrainDelta: 1.5, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "ShipWreck02_DN", label: "Ship Wreck", kind: .wreck, biome: DN, biomeArea: 3, quantity: 120, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -0.5, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "NorthVillage", label: "North Village", kind: .village, biome: DN, biomeArea: 2, quantity: 135, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 70.0, group: ""),
    .init(prefab: "ShipWreck01_DN", label: "Ship Wreck", kind: .wreck, biome: DN, biomeArea: 3, quantity: 170, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -0.5, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Grave1", label: "Grave", kind: .monument, biome: SW, biomeArea: 2, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.5, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.04, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Crypt2", label: "Burial Chamber", kind: .crypt, biome: BF, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 128.0, group: ""),
    .init(prefab: "Ruin1", label: "Ruin", kind: .ruin, biome: BF, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.70, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Ruin2", label: "Ruin", kind: .ruin, biome: BF, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 9.89, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "StoneHouse3", label: "Stone House", kind: .village, biome: BF, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 6.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "StoneHouse4", label: "Stone House", kind: .village, biome: BF, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 7.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "GoblinCamp2", label: "Fuling Village", kind: .camp, biome: PL, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 30.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 250.0, group: ""),
    .init(prefab: "TrollCave02", label: "Troll Cave", kind: .cave, biome: BF, biomeArea: 2, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 3.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 5.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 256.0, group: ""),
    .init(prefab: "Crypt3", label: "Burial Chamber", kind: .crypt, biome: BF, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 3.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 11.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 128.0, group: ""),
    .init(prefab: "Crypt4", label: "Burial Chamber", kind: .crypt, biome: BF, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 18.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 128.0, group: ""),
    .init(prefab: "DrakeNest01", label: "Drake Nest", kind: .resource, biome: MT, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 5.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 100.0, group: ""),
    .init(prefab: "Mistlands_RockSpire1", label: "Rock Spire", kind: .monument, biome: ML, biomeArea: 2, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -10.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 4.00, minTerrainDelta: 2.0, maxTerrainDelta: 99.0, minDistanceFromSimilar: 60.0, group: ""),
    .init(prefab: "Mistlands_StatueGroup1", label: "Statue Group", kind: .monument, biome: ML, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 16.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 32.0, group: ""),
    .init(prefab: "Mistlands_Statue1", label: "Statue", kind: .monument, biome: ML, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 6.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Mistlands_Statue2", label: "Statue", kind: .monument, biome: ML, biomeArea: 3, quantity: 200, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 6.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "Greydwarf_camp1", label: "Greydwarf Nest", kind: .camp, biome: BF, biomeArea: 2, quantity: 300, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: ""),
    .init(prefab: "CharredStone_Spawner", label: "Charred Stone Spawner", kind: .resource, biome: AL, biomeArea: 3, quantity: 300, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 20.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 100.0, group: ""),
    .init(prefab: "VoltureNest", label: "Volture Nest", kind: .resource, biome: AL, biomeArea: 3, quantity: 350, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 16.00, minTerrainDelta: 0.0, maxTerrainDelta: 5.0, minDistanceFromSimilar: 100.0, group: ""),
    .init(prefab: "Mistlands_RoadPost1", label: "Road Post", kind: .monument, biome: ML, biomeArea: 3, quantity: 500, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 6.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "InfestedTree01", label: "Infested Tree", kind: .resource, biome: SW, biomeArea: 3, quantity: 700, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 5.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 0.0, group: ""),
    .init(prefab: "AbandonedLogCabin02", label: "Abandoned Log Cabin", kind: .village, biome: MT, biomeArea: 3, quantity: 33, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.51, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Abandonedcabin"),
    .init(prefab: "AbandonedLogCabin03", label: "Abandoned Log Cabin", kind: .village, biome: MT, biomeArea: 3, quantity: 33, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Abandonedcabin"),
    .init(prefab: "AbandonedLogCabin04", label: "Abandoned Log Cabin", kind: .village, biome: MT, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Abandonedcabin"),
    .init(prefab: "Mistlands_GuardTower1_ruined_new2", label: "Guard Tower1 ruined new", kind: .fortress, biome: ML, biomeArea: 2, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 128.0, group: "Dvergr"),
    .init(prefab: "Mistlands_GuardTower3_new", label: "Guard Tower", kind: .fortress, biome: ML, biomeArea: 2, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 12.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 128.0, group: "Dvergr"),
    .init(prefab: "Mistlands_GuardTower3_ruined_new", label: "Guard Tower3 ruined", kind: .fortress, biome: ML, biomeArea: 2, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 11.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 128.0, group: "Dvergr"),
    .init(prefab: "Mistlands_GuardTower1_new", label: "Guard Tower", kind: .fortress, biome: ML, biomeArea: 2, quantity: 75, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 128.0, group: "Dvergr"),
    .init(prefab: "Mistlands_GuardTower2_new", label: "Guard Tower", kind: .fortress, biome: ML, biomeArea: 2, quantity: 75, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 4.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 128.0, group: "Dvergr"),
    .init(prefab: "Mistlands_GuardTower1_ruined_new", label: "Guard Tower1 ruined", kind: .fortress, biome: ML, biomeArea: 2, quantity: 80, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 128.0, group: "Dvergr"),
    .init(prefab: "Mistlands_Lighthouse1_new", label: "Lighthouse", kind: .monument, biome: ML, biomeArea: 2, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 0.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 128.0, group: "Dvergr"),
    .init(prefab: "Mistlands_Excavation1", label: "Excavation", kind: .mine, biome: ML, biomeArea: 2, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 4.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 128.0, group: "Excavation"),
    .init(prefab: "Mistlands_Excavation2", label: "Excavation", kind: .mine, biome: ML, biomeArea: 2, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 4.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 128.0, group: "Excavation"),
    .init(prefab: "Mistlands_Excavation3", label: "Excavation", kind: .mine, biome: ML, biomeArea: 2, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 4.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 17.00, minTerrainDelta: 0.0, maxTerrainDelta: 5.0, minDistanceFromSimilar: 96.0, group: "Excavation"),
    .init(prefab: "FireHole", label: "Fire Hole", kind: .cave, biome: SW, biomeArea: 2, quantity: 75, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 5.00, minTerrainDelta: 0.0, maxTerrainDelta: 5.0, minDistanceFromSimilar: 16.0, group: "FireHole"),
    .init(prefab: "FrozenShip01_DN", label: "Frozen Ship", kind: .wreck, biome: DN, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -15.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 100.0, minDistanceFromSimilar: 64.0, group: "FrozenShip"),
    .init(prefab: "FrozenShip02_DN", label: "Frozen Ship", kind: .wreck, biome: DN, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -15.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 16.00, minTerrainDelta: 0.0, maxTerrainDelta: 100.0, minDistanceFromSimilar: 64.0, group: "FrozenShip"),
    .init(prefab: "FrozenShip03_DN", label: "Frozen Ship", kind: .wreck, biome: DN, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -15.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 100.0, minDistanceFromSimilar: 64.0, group: "FrozenShip"),
    .init(prefab: "Mistlands_Giant2", label: "Giant", kind: .resource, biome: ML, biomeArea: 2, quantity: 85, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 256.0, group: "Giant"),
    .init(prefab: "Mistlands_Giant1", label: "Giant", kind: .resource, biome: ML, biomeArea: 2, quantity: 250, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 11.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 180.0, group: "Giant"),
    .init(prefab: "Mistlands_Swords1", label: "Swords", kind: .monument, biome: ML, biomeArea: 2, quantity: 33, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 256.0, group: "GiantArmor"),
    .init(prefab: "Mistlands_Swords2", label: "Swords", kind: .monument, biome: ML, biomeArea: 2, quantity: 33, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 256.0, group: "GiantArmor"),
    .init(prefab: "Mistlands_Swords3", label: "Swords", kind: .monument, biome: ML, biomeArea: 2, quantity: 33, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 256.0, group: "GiantArmor"),
    .init(prefab: "Ruin3", label: "Ruin", kind: .ruin, biome: PL, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 512.0, group: "Goblintower"),
    .init(prefab: "StoneTower1", label: "Stone Tower", kind: .fortress, biome: PL, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 14.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 512.0, group: "Goblintower"),
    .init(prefab: "StoneTower3", label: "Stone Tower", kind: .fortress, biome: PL, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 14.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 512.0, group: "Goblintower"),
    .init(prefab: "Mistlands_Harbour1", label: "Harbour", kind: .village, biome: ML, biomeArea: 1, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 2.0, maxTerrainDelta: 20.0, minDistanceFromSimilar: 64.0, group: "Harbour"),
    .init(prefab: "Mistlands_Viaduct1", label: "Viaduct", kind: .monument, biome: ML, biomeArea: 2, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 24.00, minTerrainDelta: 2.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 128.0, group: "Harbour"),
    .init(prefab: "Mistlands_Viaduct2", label: "Viaduct", kind: .monument, biome: ML, biomeArea: 2, quantity: 150, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 4.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 64.0, group: "Harbour"),
    .init(prefab: "IcePond1", label: "Ice Pond", kind: .resource, biome: DN, biomeArea: 2, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 10.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 0.0, maxTerrainDelta: 1.5, minDistanceFromSimilar: 128.0, group: "icepond"),
    .init(prefab: "NorthMemorialPlace", label: "North Memorial Place", kind: .monument, biome: DN, biomeArea: 2, quantity: 15, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 25.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 400.0, group: "memorialplace"),
    .init(prefab: "MorgenHole1", label: "Morgen Hole", kind: .cave, biome: AL, biomeArea: 2, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 300.0, group: "MorgenHole"),
    .init(prefab: "MorgenHole2", label: "Morgen Hole", kind: .cave, biome: AL, biomeArea: 2, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 200.0, group: "MorgenHole"),
    .init(prefab: "MorgenHole3", label: "Morgen Hole", kind: .cave, biome: AL, biomeArea: 2, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 200.0, group: "MorgenHole"),
    .init(prefab: "MorkBorg", label: "Mork Borg", kind: .mystery, biome: DN, biomeArea: 3, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 30.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 30.00, minTerrainDelta: 0.0, maxTerrainDelta: 300.0, minDistanceFromSimilar: 275.0, group: "morkborg"),
    .init(prefab: "MountainCave02", label: "Frost Cave", kind: .cave, biome: MT, biomeArea: 3, quantity: 120, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 15.00, minTerrainDelta: 0.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 200.0, group: "mountaincaves"),
    .init(prefab: "StoneTowerRuins04", label: "Stone Tower Ruins", kind: .ruin, biome: MT, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 150.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.28, minTerrainDelta: 6.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 128.0, group: "Mountainruin"),
    .init(prefab: "StoneTowerRuins05", label: "Stone Tower Ruins", kind: .ruin, biome: MT, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 150.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 22.00, minTerrainDelta: 6.0, maxTerrainDelta: 40.0, minDistanceFromSimilar: 128.0, group: "Mountainruin"),
    .init(prefab: "DN_hut01", label: "Hut", kind: .village, biome: DN, biomeArea: 2, quantity: 40, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 40.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 100.0, group: "northvillage"),
    .init(prefab: "Runestone_Greydwarfs", label: "Greydwarfs", kind: .runestone, biome: BF, biomeArea: 3, quantity: 25, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 99.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "Runestone_Draugr", label: "Draugr", kind: .runestone, biome: SW, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.5, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "DrakeLorestone", label: "Drake Lorestone", kind: .runestone, biome: MT, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 4.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "Runestone_Boars", label: "Boars", kind: .runestone, biome: M, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "Runestone_BlackForest", label: "Black Forest", kind: .runestone, biome: BF, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "Runestone_Mistlands", label: "Mistlands", kind: .runestone, biome: ML, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "Runestone_Ashlands", label: "Ashlands", kind: .runestone, biome: AL, biomeArea: 3, quantity: 70, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "Runestone_DeepNorth", label: "Deep North", kind: .runestone, biome: DN, biomeArea: 3, quantity: 70, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "Runestone_Meadows", label: "Meadows", kind: .runestone, biome: M, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "Runestone_Swamps", label: "Swamps", kind: .runestone, biome: SW, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "Runestone_Mountains", label: "Mountains", kind: .runestone, biome: MT, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 100.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "Runestone_Plains", label: "Plains", kind: .runestone, biome: PL, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Runestones"),
    .init(prefab: "ShipSetting03", label: "Ship Setting", kind: .monument, biome: DN, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 0.50, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 64.0, group: "shipsetting"),
    .init(prefab: "ShipSetting02", label: "Ship Setting", kind: .monument, biome: DN, biomeArea: 3, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 0.50, exteriorRadius: 24.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 64.0, group: "shipsetting"),
    .init(prefab: "ShipWreck01", label: "Ship Wreck", kind: .wreck, biome: SW|BF|PL|OC, biomeArea: 3, quantity: 25, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 1024.0, group: "Shipwreck"),
    .init(prefab: "ShipWreck02", label: "Ship Wreck", kind: .wreck, biome: SW|BF|PL|OC, biomeArea: 3, quantity: 25, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 1024.0, group: "Shipwreck"),
    .init(prefab: "ShipWreck03", label: "Ship Wreck", kind: .wreck, biome: SW|BF|PL|OC, biomeArea: 3, quantity: 25, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 1024.0, group: "Shipwreck"),
    .init(prefab: "ShipWreck04", label: "Ship Wreck", kind: .wreck, biome: SW|BF|PL|OC, biomeArea: 3, quantity: 25, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 14.00, minTerrainDelta: 0.0, maxTerrainDelta: 10.0, minDistanceFromSimilar: 1024.0, group: "Shipwreck"),
    .init(prefab: "StoneHenge1", label: "Stone Henge", kind: .monument, biome: PL, biomeArea: 3, quantity: 5, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 30.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 1000.0, group: "Stonehenge"),
    .init(prefab: "StoneHenge2", label: "Stone Henge", kind: .monument, biome: PL, biomeArea: 3, quantity: 5, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 30.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 1000.0, group: "Stonehenge"),
    .init(prefab: "StoneHenge3", label: "Stone Henge", kind: .monument, biome: PL, biomeArea: 3, quantity: 5, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 30.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 1000.0, group: "Stonehenge"),
    .init(prefab: "StoneHenge4", label: "Stone Henge", kind: .monument, biome: PL, biomeArea: 3, quantity: 5, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 30.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 1000.0, group: "Stonehenge"),
    .init(prefab: "StoneHenge5", label: "Stone Henge", kind: .monument, biome: PL, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 16.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 500.0, group: "Stonehenge"),
    .init(prefab: "StoneHenge6", label: "Stone Henge", kind: .monument, biome: PL, biomeArea: 3, quantity: 20, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 16.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 500.0, group: "Stonehenge"),
    .init(prefab: "StoneTowerRuins03", label: "Stone Tower Ruins", kind: .ruin, biome: BF, biomeArea: 3, quantity: 80, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 9.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 200.0, group: "Stonetowerruins"),
    .init(prefab: "StoneTowerRuins07", label: "Stone Tower Ruins", kind: .ruin, biome: BF, biomeArea: 3, quantity: 80, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 9.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 200.0, group: "Stonetowerruins"),
    .init(prefab: "StoneTowerRuins08", label: "Stone Tower Ruins", kind: .ruin, biome: BF, biomeArea: 3, quantity: 80, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 9.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 200.0, group: "Stonetowerruins"),
    .init(prefab: "StoneTowerRuins09", label: "Stone Tower Ruins", kind: .ruin, biome: BF, biomeArea: 3, quantity: 80, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 7.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 200.0, group: "Stonetowerruins"),
    .init(prefab: "StoneTowerRuins10", label: "Stone Tower Ruins", kind: .ruin, biome: BF, biomeArea: 3, quantity: 80, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 7.00, minTerrainDelta: 0.0, maxTerrainDelta: 2.0, minDistanceFromSimilar: 200.0, group: "Stonetowerruins"),
    .init(prefab: "StoneTowerRuins07_sunk", label: "Stone Tower Ruins", kind: .ruin, biome: BF, biomeArea: 3, quantity: 10, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -8.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 2.00, exteriorRadius: 7.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 50.0, group: "Stonetowerruins_sunk"),
    .init(prefab: "StoneTowerRuins08_sunk", label: "Stone Tower Ruins", kind: .ruin, biome: BF, biomeArea: 3, quantity: 10, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -8.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 2.00, exteriorRadius: 7.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 50.0, group: "Stonetowerruins_sunk"),
    .init(prefab: "StoneTowerRuins09_sunk", label: "Stone Tower Ruins", kind: .ruin, biome: BF, biomeArea: 3, quantity: 10, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -8.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 2.00, exteriorRadius: 7.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 50.0, group: "Stonetowerruins_sunk"),
    .init(prefab: "StoneTowerRuins10_sunk", label: "Stone Tower Ruins", kind: .ruin, biome: BF, biomeArea: 3, quantity: 10, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -8.0, maxAltitude: 1000.0, inForest: true, forestMin: 0.00, forestMax: 2.00, exteriorRadius: 7.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 50.0, group: "Stonetowerruins_sunk"),
    .init(prefab: "SwampHut5", label: "Swamp Hut", kind: .village, biome: SW, biomeArea: 3, quantity: 25, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Swamphut"),
    .init(prefab: "SwampHut1", label: "Swamp Hut", kind: .village, biome: SW, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Swamphut"),
    .init(prefab: "SwampHut2", label: "Swamp Hut", kind: .village, biome: SW, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Swamphut"),
    .init(prefab: "SwampHut3", label: "Swamp Hut", kind: .village, biome: SW, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 2.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Swamphut"),
    .init(prefab: "SwampHut4", label: "Swamp Hut", kind: .village, biome: SW, biomeArea: 3, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 8.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 128.0, group: "Swamphut"),
    .init(prefab: "SwampRuin1", label: "Swamp Ruin", kind: .ruin, biome: SW, biomeArea: 2, quantity: 30, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -0.5, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 12.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 256.0, group: "SwampRuin"),
    .init(prefab: "SwampRuin2", label: "Swamp Ruin", kind: .ruin, biome: SW, biomeArea: 2, quantity: 30, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -0.5, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 10.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 256.0, group: "SwampRuin"),
    .init(prefab: "TarPit2", label: "Tar Pit", kind: .resource, biome: PL, biomeArea: 2, quantity: 16, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 25.00, minTerrainDelta: 0.0, maxTerrainDelta: 1.5, minDistanceFromSimilar: 128.0, group: "tarpit"),
    .init(prefab: "TarPit1", label: "Tar Pit", kind: .resource, biome: PL, biomeArea: 2, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 20.00, minTerrainDelta: 0.0, maxTerrainDelta: 1.5, minDistanceFromSimilar: 128.0, group: "tarpit"),
    .init(prefab: "TarPit3", label: "Tar Pit", kind: .resource, biome: PL, biomeArea: 2, quantity: 100, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 5.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 14.00, minTerrainDelta: 0.0, maxTerrainDelta: 1.5, minDistanceFromSimilar: 128.0, group: "tarpit"),
    .init(prefab: "LumberCamp", label: "Lumber Camp", kind: .mine, biome: DN, biomeArea: 2, quantity: 50, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 4.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 3.0, minDistanceFromSimilar: 100.0, group: "thehole"),
    .init(prefab: "CharredTowerRuins1", label: "Charred Tower Ruins", kind: .ruin, biome: AL, biomeArea: 3, quantity: 30, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 22.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 100.0, group: "towerruins"),
    .init(prefab: "CharredTowerRuins1_dvergr", label: "Charred Tower Ruins", kind: .ruin, biome: AL, biomeArea: 3, quantity: 30, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: 0.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 22.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 100.0, group: "towerruins"),
    .init(prefab: "WoodFarm1", label: "Wood Farm", kind: .village, biome: M, biomeArea: 3, quantity: 10, prioritized: false, centerFirst: false, unique: false, minDistance: 500.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 128.0, group: "woodvillage"),
    .init(prefab: "WoodVillage1", label: "Wood Village", kind: .village, biome: M, biomeArea: 3, quantity: 15, prioritized: false, centerFirst: false, unique: false, minDistance: 2000.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 256.0, group: "woodvillage"),
    .init(prefab: "WoodVillage2", label: "Wood Village", kind: .village, biome: M, biomeArea: 3, quantity: 15, prioritized: false, centerFirst: false, unique: false, minDistance: 2000.0, maxDistance: 0.0, minAltitude: 1.0, maxAltitude: 1000.0, inForest: false, forestMin: 0.00, forestMax: 1.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 4.0, minDistanceFromSimilar: 256.0, group: "woodvillage"),
    .init(prefab: "CharredRuins1", label: "Charred Ruins", kind: .ruin, biome: AL, biomeArea: 2, quantity: 75, prioritized: false, centerFirst: false, unique: false, minDistance: 0.0, maxDistance: 0.0, minAltitude: -5.0, maxAltitude: 1000.0, inForest: true, forestMin: 1.00, forestMax: 5.00, exteriorRadius: 32.00, minTerrainDelta: 0.0, maxTerrainDelta: 6.0, minDistanceFromSimilar: 256.0, group: "zigg"),
]

// MARK: - Placement

public struct Placed: Sendable {
    public let cfg: Int
    public let x: Float
    public let y: Float
}

@inline(__always)
private func zonePos(_ zx: Int32, _ zy: Int32) -> (Float, Float) {
    (Float(zx) * ZONE_SIZE, Float(zy) * ZONE_SIZE)
}

/// `GetRandomZone` — rejects zones outside the world, consuming draws each try.
@inline(__always)
private func randomZone(_ rng: inout UnityRandom, _ range: Float) -> (Int32, Int32) {
    let num = Int32(range) / 64
    while true {
        let zx = rng.range(-num, num)
        let zy = rng.range(-num, num)
        let p = zonePos(zx, zy)
        if (p.0 * p.0 + p.1 * p.1).squareRoot() < 10000.0 { return (zx, zy) }
        // num == 0 can only produce (0,0), which is inside, so this terminates.
    }
}

@inline(__always)
private func randomPointInZone(_ rng: inout UnityRandom, _ z: (Int32, Int32), _ radius: Float) -> (Float, Float) {
    let zp = zonePos(z.0, z.1)
    let x = rng.range(-32.0 + radius, 32.0 - radius)
    let y = rng.range(-32.0 + radius, 32.0 - radius)
    return (zp.0 + x, zp.1 + y)
}

/// Zone coordinates never leave ±157 (10 km world, 64 m zones), so the caches
/// are flat arrays rather than hash maps. This loop runs tens of millions of
/// times per world; hashing a tuple each time was a large share of the cost.
public let ZONE_HALF: Int32 = 192
public let ZONE_DIM: Int = Int(ZONE_HALF * 2 + 1)

@inline(__always)
private func fromBits(_ v: UInt16) -> Biome { Biome(rawValue: v) ?? .none }

@inline(__always)
private func zoneIndex(_ z: (Int32, Int32)) -> Int? {
    if z.0 < -ZONE_HALF || z.0 > ZONE_HALF || z.1 < -ZONE_HALF || z.1 > ZONE_HALF { return nil }
    return Int(z.1 + ZONE_HALF) * ZONE_DIM + Int(z.0 + ZONE_HALF)
}

/// Median when a zone and all eight neighbours share a biome, Edge otherwise.
private func biomeArea(_ wg: WorldGenerator, _ cache: inout [UInt16], _ z: (Int32, Int32)) -> UInt8 {
    func at(_ zx: Int32, _ zy: Int32) -> Biome {
        guard let i = zoneIndex((zx, zy)) else {
            let p = zonePos(zx, zy)
            return wg.biome(p.0, p.1)
        }
        if cache[i] != 0 { return fromBits(cache[i]) }
        let p = zonePos(zx, zy)
        let b = wg.biome(p.0, p.1)
        cache[i] = b.rawValue
        return b
    }
    let centre = at(z.0, z.1)
    for dy in -1...1 {
        for dx in -1...1 {
            if dx == 0 && dy == 0 { continue }
            if at(z.0 + Int32(dx), z.1 + Int32(dy)) != centre { return 1 }  // Edge
        }
    }
    return 2  // Median
}

/// The key a location competes with itself under: its group if it has one,
/// otherwise its own prefab. `m_minDistanceFromSimilar` only compares in here.
@inline(__always)
private func similarKey(_ i: Int) -> String {
    let c = LOCATIONS[i]
    return c.group.isEmpty ? c.prefab : c.group
}

@inline(__always)
private func haveInRange(_ similar: [(Float, Float)], _ p: (Float, Float), _ radius: Float) -> Bool {
    let r2 = radius * radius
    for (x, y) in similar where (x - p.0) * (x - p.0) + (y - p.1) * (y - p.1) < r2 { return true }
    return false
}

/// Resumable placement state.
///
/// Placement cannot be parallelised or reordered — one shared occupancy map,
/// one location per 64 m zone across *all* types, prioritised types first — so
/// the only way to show progress is to run it type by type and hand back what
/// has been placed so far. That is safe to display: once a type is processed
/// its placements are final, because later types can only be blocked by
/// earlier ones, never the other way round.
public final class GenState {
    var order: [Int]
    var next: Int = 0
    /// One flag per zone — checked on every single attempt.
    var occupied: [Bool]
    var zoneCache: [UInt16]
    /// Placed positions bucketed by `similarKey`, so the
    /// min-distance-from-similar test scans tens of entries, not 12 000.
    var similar: [String: [(Float, Float)]] = [:]
    public var placed: [Placed] = []

    init() {
        // Prioritised types claim zones first; stable within each tier.
        order = Array(0..<LOCATIONS.count)
        order.sort { a, b in
            let pa = LOCATIONS[a].prioritized ? 0 : 1
            let pb = LOCATIONS[b].prioritized ? 0 : 1
            return pa == pb ? a < b : pa < pb
        }
        occupied = [Bool](repeating: false, count: ZONE_DIM * ZONE_DIM)
        zoneCache = [UInt16](repeating: 0, count: ZONE_DIM * ZONE_DIM)
    }

    public var progress: Float { Float(next) / Float(order.count) }
    public var done: Bool { next >= order.count }
}

public func beginLocations() -> GenState { GenState() }

/// Places up to `types` more location types. Returns true when finished.
@discardableResult
public func stepLocations(_ wg: WorldGenerator, _ st: GenState, _ types: Int) -> Bool {
    let end = min(st.next + types, st.order.count)
    while st.next < end {
        let ci = st.order[st.next]
        st.next += 1
        let cfg = LOCATIONS[ci]
        let key = similarKey(ci)
        var bucket = st.similar[key] ?? []

        // Each type gets its own independent stream.
        var rng = UnityRandom(seed: wg.seed &+ stableHashCode(cfg.prefab))
        let radius = cfg.exteriorRadius
        var count: Int32 = 0
        var maxRange = cfg.centerFirst ? cfg.minDistance : 10000.0
        let cap = cfg.prioritized ? 200_000 : 100_000
        var attempts = 0

        while attempts < cap && count < cfg.quantity {
            let zone = randomZone(&rng, maxRange)
            if cfg.centerFirst { maxRange += 1.0 }
            let zi = zoneIndex(zone)
            if !(zi.map { st.occupied[$0] } ?? false) {
                let area = biomeArea(wg, &st.zoneCache, zone)
                if cfg.biomeArea & area != 0 {
                    for _ in 0..<20 {
                        let p = randomPointInZone(&rng, zone, radius)
                        let mag = (p.0 * p.0 + p.1 * p.1).squareRoot()
                        if cfg.minDistance != 0.0 && mag < cfg.minDistance { continue }
                        if cfg.maxDistance != 0.0 && mag > cfg.maxDistance { continue }
                        let (b, base) = wg.biomeWithBase(p.0, p.1)
                        if cfg.biome & b.rawValue == 0 { continue }
                        let y = wg.biomeHeightWithBase(b, p.0, p.1, base)
                        let alt = y - WATER_LEVEL_LOC
                        if alt < cfg.minAltitude || alt > cfg.maxAltitude { continue }
                        if cfg.inForest {
                            let ff = wg.forestFactor(p.0, p.1)
                            if ff < cfg.forestMin || ff > cfg.forestMax { continue }
                        }
                        // Consumes 20 RNG values; only reached past the checks above.
                        let delta = wg.terrainDelta(p.0, p.1, radius, &rng)
                        if delta > cfg.maxTerrainDelta || delta < cfg.minTerrainDelta { continue }
                        if cfg.minDistanceFromSimilar > 0.0
                            && haveInRange(bucket, p, cfg.minDistanceFromSimilar) { continue }
                        if let i = zi { st.occupied[i] = true }
                        bucket.append(p)
                        st.placed.append(Placed(cfg: ci, x: p.0, y: p.1))
                        count += 1
                        break
                    }
                }
            }
            attempts += 1
        }
        st.similar[key] = bucket
    }
    return st.done
}

public func generateLocations(_ wg: WorldGenerator) -> [Placed] {
    let st = beginLocations()
    while !stepLocations(wg, st, 32) {}
    return st.placed
}
