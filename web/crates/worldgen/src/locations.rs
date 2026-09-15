//! Point-of-interest placement — a port of `ZoneSystem.GenerateLocations`.
//!
//! Placement is rejection sampling over 64 m zones, and the RNG draw order is
//! load-bearing: `GetTerrainDelta` alone consumes 20 values (10 calls to
//! `insideUnitCircle`, a closed-form polar method drawing 2 each), and it is
//! only reached when the cheaper checks above it pass. Reorder the checks and
//! every position downstream changes.
//!
//! Locations are placed into one shared occupancy map, prioritised types
//! first, so an earlier type can block a later one — they cannot be generated
//! independently.

use crate::geo::{Biome, WorldGenerator};
use crate::random::{stable_hash_code, UnityRandom};
use std::collections::HashMap;

pub const ZONE_SIZE: f32 = 64.0;
const WATER_LEVEL: f32 = 30.0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum Kind {
    Spawn = 0,
    Boss = 1,
    Trader = 2,
    Crypt = 3,
    Camp = 4,
    Cave = 5,
    Mine = 6,
    Fortress = 7,
    Runestone = 8,
    Ruin = 9,
    Village = 10,
    Wreck = 11,
    Monument = 12,
    Resource = 13,
    Mystery = 14,
}

pub struct LocationConfig {
    pub prefab: &'static str,
    pub label: &'static str,
    pub kind: Kind,
    /// Heightmap.Biome bitmask.
    pub biome: u16,
    /// 1 = Edge, 2 = Median, 3 = Everything.
    pub biome_area: u8,
    pub quantity: i32,
    pub prioritized: bool,
    pub center_first: bool,
    pub unique: bool,
    pub min_distance: f32,
    pub max_distance: f32,
    pub min_altitude: f32,
    pub max_altitude: f32,
    pub in_forest: bool,
    pub forest_min: f32,
    pub forest_max: f32,
    pub exterior_radius: f32,
    pub min_terrain_delta: f32,
    pub max_terrain_delta: f32,
    pub min_distance_from_similar: f32,
    pub group: &'static str,
}

const M: u16 = 1;
const SW: u16 = 2;
const MT: u16 = 4;
const BF: u16 = 8;
const PL: u16 = 16;
const AL: u16 = 32;
const ML: u16 = 512;
const DN: u16 = 64;
#[allow(dead_code)]
const OC: u16 = 256;

#[allow(dead_code)]
const EDGE: u8 = 1;
#[allow(dead_code)]
const MEDIAN: u8 = 2;
#[allow(dead_code)]
const EVERYTHING: u8 = 3;

/// Placement parameters live in Unity asset bundles, not the game DLL. These
/// are transcribed from Jötunn's auto-generated location list, dumped from a
/// running **Valheim 1.0.7** — the closest thing to ground truth available
/// without the game files.
///
/// Things worth knowing when reading this against other sources:
///
///   * **`biome_area` is mostly `MEDIAN`, not `EVERYTHING`.** 67 of the 183
///     live location types are Median-only, including every boss altar, the
///     start temple and all three traders. Median means the location only
///     places in a zone whose eight neighbours all share its biome, so these
///     never generate near a biome edge. An earlier version of this table had
///     them as `EVERYTHING` on the theory that the dump's "Edge Median" was a
///     bitmask being misread; it is a bitmask, but plenty of types genuinely
///     carry only the Median bit, and treating those as Everything moves boss
///     and trader markers to places the game never puts them.
///
///   * **No location carries a max distance.** Bosses are spread across their
///     whole biome, not confined to an inner ring.
///
///   * **`m_unique` does not cap the loop.** It is checked once *before*
///     placement begins, to skip regeneration on an existing world.
///
///   * **The forest columns are the least trustworthy data here.** JotunnDoc
///     emits them through an inverted ternary — it prints "Forest Threshold"
///     when the constraint is *not* active and omits it when it is — so the
///     dump cannot be decoded for this field. The values for the 21 types that
///     predate this table are preserved from the earlier transcription; the
///     rest take the printed range at face value, which is what the dump
///     plainly intends and what every other consumer of it does.
pub static LOCATIONS: &[LocationConfig] = &[
    // ── prioritised: placed first, and they claim zones the rest cannot ──
    LocationConfig { prefab: "StartTemple", label: "Sacrificial Stones", kind: Kind::Spawn,
        biome: M, biome_area: 2, quantity: 1, prioritized: true, center_first: true,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 3.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 25.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Eikthyrnir", label: "Eikthyr", kind: Kind::Boss,
        biome: M, biome_area: 2, quantity: 3, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Dragonqueen", label: "Moder", kind: Kind::Boss,
        biome: MT, biome_area: 2, quantity: 3, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 150.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 3000.0, group: "" },
    LocationConfig { prefab: "Hildir_cave", label: "Howling Caverns", kind: Kind::Ruin,
        biome: MT, biome_area: 2, quantity: 3, prioritized: true, center_first: false,
        unique: false, min_distance: 1000.0, max_distance: 0.0, min_altitude: 200.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 15.00,
        min_terrain_delta: 0.0, max_terrain_delta: 40.0, min_distance_from_similar: 2000.0, group: "" },
    LocationConfig { prefab: "Hildir_crypt", label: "Smouldering Tombs", kind: Kind::Crypt,
        biome: BF, biome_area: 2, quantity: 3, prioritized: true, center_first: false,
        unique: false, min_distance: 3000.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 18.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 3000.0, group: "" },
    LocationConfig { prefab: "Hildir_plainsfortress", label: "Sealed Tower", kind: Kind::Ruin,
        biome: PL, biome_area: 2, quantity: 3, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 8.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 3000.0, group: "" },
    LocationConfig { prefab: "GoblinKing", label: "Yagluth", kind: Kind::Boss,
        biome: PL, biome_area: 2, quantity: 4, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 3000.0, group: "" },
    LocationConfig { prefab: "GDKing", label: "The Elder", kind: Kind::Boss,
        biome: BF, biome_area: 2, quantity: 4, prioritized: true, center_first: false,
        unique: false, min_distance: 1000.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 25.00,
        min_terrain_delta: 0.0, max_terrain_delta: 5.0, min_distance_from_similar: 3000.0, group: "" },
    LocationConfig { prefab: "Bonemass", label: "Bonemass", kind: Kind::Boss,
        biome: SW, biome_area: 2, quantity: 5, prioritized: true, center_first: false,
        unique: false, min_distance: 2000.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 19.79,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 3000.0, group: "" },
    LocationConfig { prefab: "Vendor_BlackForest", label: "Haldor", kind: Kind::Trader,
        biome: BF, biome_area: 2, quantity: 10, prioritized: true, center_first: false,
        unique: true, min_distance: 1500.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 512.0, group: "" },
    LocationConfig { prefab: "Hildir_camp", label: "Hildir", kind: Kind::Trader,
        biome: M, biome_area: 3, quantity: 10, prioritized: true, center_first: false,
        unique: true, min_distance: 3000.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 1000.0, group: "" },
    LocationConfig { prefab: "BogWitch_Camp", label: "Bog Witch", kind: Kind::Trader,
        biome: SW, biome_area: 2, quantity: 10, prioritized: true, center_first: false,
        unique: true, min_distance: 3000.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 1000.0, group: "" },
    LocationConfig { prefab: "AncientUpgradeStation", label: "Ancient Upgrade Station", kind: Kind::Mystery,
        biome: MT, biome_area: 2, quantity: 10, prioritized: true, center_first: false,
        unique: true, min_distance: 200.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 22.00,
        min_terrain_delta: 0.0, max_terrain_delta: 40.0, min_distance_from_similar: 400.0, group: "AncientUpgradeStation" },
    LocationConfig { prefab: "DN_Bossroom", label: "Fimbulbringer", kind: Kind::Boss,
        biome: DN, biome_area: 3, quantity: 3, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 80.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 6.0, min_distance_from_similar: 1024.0, group: "dn_boss" },
    LocationConfig { prefab: "Mistlands_DvergrBossEntrance1", label: "The Queen", kind: Kind::Boss,
        biome: ML, biome_area: 2, quantity: 5, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 40.0, min_distance_from_similar: 2048.0, group: "DvergrBoss" },
    LocationConfig { prefab: "Mistlands_DvergrTownEntrance1", label: "Infested Mine", kind: Kind::Mine,
        biome: ML, biome_area: 2, quantity: 120, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 12.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 5.0, max_terrain_delta: 40.0, min_distance_from_similar: 256.0, group: "DvergrDungeon" },
    LocationConfig { prefab: "Mistlands_DvergrTownEntrance2", label: "Infested Mine", kind: Kind::Mine,
        biome: ML, biome_area: 2, quantity: 120, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 40.0, min_distance_from_similar: 256.0, group: "DvergrDungeon" },
    LocationConfig { prefab: "FaderLocation", label: "Fader", kind: Kind::Boss,
        biome: AL, biome_area: 2, quantity: 3, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 40.0, min_distance_from_similar: 2048.0, group: "FaderBoss" },
    LocationConfig { prefab: "CharredFortress", label: "Charred Fortress", kind: Kind::Fortress,
        biome: AL, biome_area: 3, quantity: 20, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 20.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 256.0, group: "FaderBoss" },
    LocationConfig { prefab: "PlaceofMystery1", label: "Placeof Mystery", kind: Kind::Mystery,
        biome: AL, biome_area: 2, quantity: 1, prioritized: true, center_first: false,
        unique: true, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 5.0, min_distance_from_similar: 2048.0, group: "PlaceofMystery" },
    LocationConfig { prefab: "PlaceofMystery2", label: "Placeof Mystery", kind: Kind::Mystery,
        biome: AL, biome_area: 2, quantity: 1, prioritized: true, center_first: false,
        unique: true, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 5.0, min_distance_from_similar: 2048.0, group: "PlaceofMystery" },
    LocationConfig { prefab: "PlaceofMystery3", label: "Placeof Mystery", kind: Kind::Mystery,
        biome: AL, biome_area: 2, quantity: 1, prioritized: true, center_first: false,
        unique: true, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 5.0, min_distance_from_similar: 2048.0, group: "PlaceofMystery" },
    LocationConfig { prefab: "SunkenCrypt4", label: "Sunken Crypt", kind: Kind::Crypt,
        biome: SW, biome_area: 2, quantity: 175, prioritized: true, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 64.0, group: "SunkenCrypt" },

    // ── the rest, in dump order ───────────────────────────────────────────
    LocationConfig { prefab: "CombatRuin01", label: "Combat Ruin", kind: Kind::Ruin,
        biome: M, biome_area: 3, quantity: 5, prioritized: false, center_first: false,
        unique: false, min_distance: 1500.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 13.00,
        min_terrain_delta: 0.0, max_terrain_delta: 1.5, min_distance_from_similar: 2000.0, group: "" },
    LocationConfig { prefab: "GoblinCamp2_1", label: "Goblin Camp", kind: Kind::Camp,
        biome: PL, biome_area: 3, quantity: 5, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 30.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "BigRockClearing", label: "Big Rock Clearing", kind: Kind::Mystery,
        biome: BF, biome_area: 2, quantity: 10, prioritized: false, center_first: false,
        unique: true, min_distance: 1000.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 15.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 2000.0, group: "" },
    LocationConfig { prefab: "StoneTowerRuins05_leet", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: MT, biome_area: 3, quantity: 10, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 150.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 22.00,
        min_terrain_delta: 0.0, max_terrain_delta: 40.0, min_distance_from_similar: 32.0, group: "" },
    LocationConfig { prefab: "WoodHouse1", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse2", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse3", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse4", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse5", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse6", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse7", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse8", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse9", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse10", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse11", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse12", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 6.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "WoodHouse13", label: "Wood House", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 9.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "GoblinHut03", label: "Goblin Hut", kind: Kind::Camp,
        biome: PL, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "TarPit2_1", label: "Tar Pit", kind: Kind::Resource,
        biome: PL, biome_area: 2, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 3.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 25.00,
        min_terrain_delta: 0.0, max_terrain_delta: 1.5, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "StoneCircle", label: "Stone Circle", kind: Kind::Monument,
        biome: M, biome_area: 3, quantity: 25, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 16.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 200.0, group: "" },
    LocationConfig { prefab: "SwampWell1", label: "Swamp Well", kind: Kind::Resource,
        biome: SW, biome_area: 3, quantity: 25, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 1024.0, group: "" },
    LocationConfig { prefab: "MountainWell1", label: "Mountain Well", kind: Kind::Resource,
        biome: MT, biome_area: 3, quantity: 25, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 14.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 256.0, group: "" },
    LocationConfig { prefab: "CharredTowerRuins3", label: "Charred Tower Ruins", kind: Kind::Ruin,
        biome: AL, biome_area: 3, quantity: 30, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 500.0, group: "" },
    LocationConfig { prefab: "DN_gammeltrollFrac01", label: "Gammeltroll Frac", kind: Kind::Ruin,
        biome: DN, biome_area: 3, quantity: 30, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "DN_gammeltrollFrac02", label: "Gammeltroll Frac", kind: Kind::Ruin,
        biome: DN, biome_area: 3, quantity: 30, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 10.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "GoblinHut01", label: "Goblin Hut", kind: Kind::Camp,
        biome: PL, biome_area: 3, quantity: 30, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 6.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "GoblinHut02", label: "Goblin Hut", kind: Kind::Camp,
        biome: PL, biome_area: 3, quantity: 30, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 7.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "CharredTowerRuins2", label: "Charred Tower Ruins", kind: Kind::Ruin,
        biome: AL, biome_area: 3, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "TheHole01", label: "The Hole", kind: Kind::Cave,
        biome: DN, biome_area: 2, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 28.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 256.0, group: "" },
    LocationConfig { prefab: "Dolmen03", label: "Dolmen", kind: Kind::Monument,
        biome: M|BF, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Waymarker01", label: "Waymarker", kind: Kind::Monument,
        biome: MT, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 3.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Waymarker02", label: "Waymarker", kind: Kind::Monument,
        biome: MT, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 3.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "BearCave", label: "Bear Cave", kind: Kind::Cave,
        biome: BF, biome_area: 2, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 12.00,
        min_terrain_delta: 5.0, max_terrain_delta: 10.0, min_distance_from_similar: 256.0, group: "" },
    LocationConfig { prefab: "SwampHut1_1", label: "Swamp Hut", kind: Kind::Village,
        biome: SW, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "SwampHut2_1", label: "Swamp Hut", kind: Kind::Village,
        biome: SW, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "SwampHut3_1", label: "Swamp Hut", kind: Kind::Village,
        biome: SW, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "TarPit1_1", label: "Tar Pit", kind: Kind::Resource,
        biome: PL, biome_area: 2, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 3.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 0.0, max_terrain_delta: 1.5, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Dolmen01", label: "Dolmen", kind: Kind::Monument,
        biome: M|BF, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Dolmen02", label: "Dolmen", kind: Kind::Monument,
        biome: M|BF, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "ShipSetting01", label: "Ship Setting", kind: Kind::Monument,
        biome: M, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "" },
    LocationConfig { prefab: "MountainGrave01", label: "Mountain Grave", kind: Kind::Monument,
        biome: MT, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 3.93,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 50.0, group: "" },
    LocationConfig { prefab: "FortressRuins", label: "Fortress Ruins", kind: Kind::Fortress,
        biome: AL, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "LeviathanLava", label: "Lava Leviathan", kind: Kind::Ruin,
        biome: AL, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 10.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "SulfurArch", label: "Sulfur Arch", kind: Kind::Monument,
        biome: AL, biome_area: 2, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 10.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 30.00,
        min_terrain_delta: 0.0, max_terrain_delta: 6.0, min_distance_from_similar: 40.0, group: "" },
    LocationConfig { prefab: "AshlandRuins", label: "Ashland Ruins", kind: Kind::Ruin,
        biome: AL, biome_area: 2, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 16.0, group: "" },
    LocationConfig { prefab: "CharredRuins2", label: "Charred Ruins", kind: Kind::Ruin,
        biome: AL, biome_area: 2, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -5.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 15.00,
        min_terrain_delta: 0.0, max_terrain_delta: 30.0, min_distance_from_similar: 128.0, group: "" },
    LocationConfig { prefab: "CharredRuins3", label: "Charred Ruins", kind: Kind::Ruin,
        biome: AL, biome_area: 2, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -5.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 30.0, min_distance_from_similar: 128.0, group: "" },
    LocationConfig { prefab: "CharredRuins4", label: "Charred Ruins", kind: Kind::Ruin,
        biome: AL, biome_area: 2, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -5.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 30.0, min_distance_from_similar: 128.0, group: "" },
    LocationConfig { prefab: "TarPit3_1", label: "Tar Pit", kind: Kind::Resource,
        biome: PL, biome_area: 2, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 3.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 14.00,
        min_terrain_delta: 0.0, max_terrain_delta: 1.5, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "ShipWreck02_DN", label: "Ship Wreck", kind: Kind::Wreck,
        biome: DN, biome_area: 3, quantity: 120, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -0.5, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "NorthVillage", label: "North Village", kind: Kind::Village,
        biome: DN, biome_area: 2, quantity: 135, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 70.0, group: "" },
    LocationConfig { prefab: "ShipWreck01_DN", label: "Ship Wreck", kind: Kind::Wreck,
        biome: DN, biome_area: 3, quantity: 170, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -0.5, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Grave1", label: "Grave", kind: Kind::Monument,
        biome: SW, biome_area: 2, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.5, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.04,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Crypt2", label: "Burial Chamber", kind: Kind::Crypt,
        biome: BF, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 128.0, group: "" },
    LocationConfig { prefab: "Ruin1", label: "Ruin", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.70,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Ruin2", label: "Ruin", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 9.89,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "StoneHouse3", label: "Stone House", kind: Kind::Village,
        biome: BF, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 6.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "StoneHouse4", label: "Stone House", kind: Kind::Village,
        biome: BF, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 7.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "GoblinCamp2", label: "Fuling Village", kind: Kind::Camp,
        biome: PL, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 30.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 250.0, group: "" },
    LocationConfig { prefab: "TrollCave02", label: "Troll Cave", kind: Kind::Cave,
        biome: BF, biome_area: 2, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 3.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 5.0, max_terrain_delta: 10.0, min_distance_from_similar: 256.0, group: "" },
    LocationConfig { prefab: "Crypt3", label: "Burial Chamber", kind: Kind::Crypt,
        biome: BF, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 3.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 11.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 128.0, group: "" },
    LocationConfig { prefab: "Crypt4", label: "Burial Chamber", kind: Kind::Crypt,
        biome: BF, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 18.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 128.0, group: "" },
    LocationConfig { prefab: "DrakeNest01", label: "Drake Nest", kind: Kind::Resource,
        biome: MT, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 5.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 100.0, group: "" },
    LocationConfig { prefab: "Mistlands_RockSpire1", label: "Rock Spire", kind: Kind::Monument,
        biome: ML, biome_area: 2, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -10.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 4.00,
        min_terrain_delta: 2.0, max_terrain_delta: 99.0, min_distance_from_similar: 60.0, group: "" },
    LocationConfig { prefab: "Mistlands_StatueGroup1", label: "Statue Group", kind: Kind::Monument,
        biome: ML, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 16.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 32.0, group: "" },
    LocationConfig { prefab: "Mistlands_Statue1", label: "Statue", kind: Kind::Monument,
        biome: ML, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 6.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Mistlands_Statue2", label: "Statue", kind: Kind::Monument,
        biome: ML, biome_area: 3, quantity: 200, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 6.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "Greydwarf_camp1", label: "Greydwarf Nest", kind: Kind::Camp,
        biome: BF, biome_area: 2, quantity: 300, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "" },
    LocationConfig { prefab: "CharredStone_Spawner", label: "Charred Stone Spawner", kind: Kind::Resource,
        biome: AL, biome_area: 3, quantity: 300, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 20.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 100.0, group: "" },
    LocationConfig { prefab: "VoltureNest", label: "Volture Nest", kind: Kind::Resource,
        biome: AL, biome_area: 3, quantity: 350, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 16.00,
        min_terrain_delta: 0.0, max_terrain_delta: 5.0, min_distance_from_similar: 100.0, group: "" },
    LocationConfig { prefab: "Mistlands_RoadPost1", label: "Road Post", kind: Kind::Monument,
        biome: ML, biome_area: 3, quantity: 500, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 6.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "InfestedTree01", label: "Infested Tree", kind: Kind::Resource,
        biome: SW, biome_area: 3, quantity: 700, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 5.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 0.0, group: "" },
    LocationConfig { prefab: "AbandonedLogCabin02", label: "Abandoned Log Cabin", kind: Kind::Village,
        biome: MT, biome_area: 3, quantity: 33, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.51,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Abandonedcabin" },
    LocationConfig { prefab: "AbandonedLogCabin03", label: "Abandoned Log Cabin", kind: Kind::Village,
        biome: MT, biome_area: 3, quantity: 33, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Abandonedcabin" },
    LocationConfig { prefab: "AbandonedLogCabin04", label: "Abandoned Log Cabin", kind: Kind::Village,
        biome: MT, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Abandonedcabin" },
    LocationConfig { prefab: "Mistlands_GuardTower1_ruined_new2", label: "Guard Tower1 ruined new", kind: Kind::Fortress,
        biome: ML, biome_area: 2, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 128.0, group: "Dvergr" },
    LocationConfig { prefab: "Mistlands_GuardTower3_new", label: "Guard Tower", kind: Kind::Fortress,
        biome: ML, biome_area: 2, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 12.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 128.0, group: "Dvergr" },
    LocationConfig { prefab: "Mistlands_GuardTower3_ruined_new", label: "Guard Tower3 ruined", kind: Kind::Fortress,
        biome: ML, biome_area: 2, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 11.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 128.0, group: "Dvergr" },
    LocationConfig { prefab: "Mistlands_GuardTower1_new", label: "Guard Tower", kind: Kind::Fortress,
        biome: ML, biome_area: 2, quantity: 75, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 128.0, group: "Dvergr" },
    LocationConfig { prefab: "Mistlands_GuardTower2_new", label: "Guard Tower", kind: Kind::Fortress,
        biome: ML, biome_area: 2, quantity: 75, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 4.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 128.0, group: "Dvergr" },
    LocationConfig { prefab: "Mistlands_GuardTower1_ruined_new", label: "Guard Tower1 ruined", kind: Kind::Fortress,
        biome: ML, biome_area: 2, quantity: 80, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 128.0, group: "Dvergr" },
    LocationConfig { prefab: "Mistlands_Lighthouse1_new", label: "Lighthouse", kind: Kind::Monument,
        biome: ML, biome_area: 2, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 0.0, max_terrain_delta: 40.0, min_distance_from_similar: 128.0, group: "Dvergr" },
    LocationConfig { prefab: "Mistlands_Excavation1", label: "Excavation", kind: Kind::Mine,
        biome: ML, biome_area: 2, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 4.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 128.0, group: "Excavation" },
    LocationConfig { prefab: "Mistlands_Excavation2", label: "Excavation", kind: Kind::Mine,
        biome: ML, biome_area: 2, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 4.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 128.0, group: "Excavation" },
    LocationConfig { prefab: "Mistlands_Excavation3", label: "Excavation", kind: Kind::Mine,
        biome: ML, biome_area: 2, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 4.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 17.00,
        min_terrain_delta: 0.0, max_terrain_delta: 5.0, min_distance_from_similar: 96.0, group: "Excavation" },
    LocationConfig { prefab: "FireHole", label: "Fire Hole", kind: Kind::Cave,
        biome: SW, biome_area: 2, quantity: 75, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 5.00,
        min_terrain_delta: 0.0, max_terrain_delta: 5.0, min_distance_from_similar: 16.0, group: "FireHole" },
    LocationConfig { prefab: "FrozenShip01_DN", label: "Frozen Ship", kind: Kind::Wreck,
        biome: DN, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -15.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 100.0, min_distance_from_similar: 64.0, group: "FrozenShip" },
    LocationConfig { prefab: "FrozenShip02_DN", label: "Frozen Ship", kind: Kind::Wreck,
        biome: DN, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -15.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 16.00,
        min_terrain_delta: 0.0, max_terrain_delta: 100.0, min_distance_from_similar: 64.0, group: "FrozenShip" },
    LocationConfig { prefab: "FrozenShip03_DN", label: "Frozen Ship", kind: Kind::Wreck,
        biome: DN, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -15.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 100.0, min_distance_from_similar: 64.0, group: "FrozenShip" },
    LocationConfig { prefab: "Mistlands_Giant2", label: "Giant", kind: Kind::Resource,
        biome: ML, biome_area: 2, quantity: 85, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 256.0, group: "Giant" },
    LocationConfig { prefab: "Mistlands_Giant1", label: "Giant", kind: Kind::Resource,
        biome: ML, biome_area: 2, quantity: 250, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 11.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 180.0, group: "Giant" },
    LocationConfig { prefab: "Mistlands_Swords1", label: "Swords", kind: Kind::Monument,
        biome: ML, biome_area: 2, quantity: 33, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 256.0, group: "GiantArmor" },
    LocationConfig { prefab: "Mistlands_Swords2", label: "Swords", kind: Kind::Monument,
        biome: ML, biome_area: 2, quantity: 33, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 256.0, group: "GiantArmor" },
    LocationConfig { prefab: "Mistlands_Swords3", label: "Swords", kind: Kind::Monument,
        biome: ML, biome_area: 2, quantity: 33, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 256.0, group: "GiantArmor" },
    LocationConfig { prefab: "Ruin3", label: "Ruin", kind: Kind::Ruin,
        biome: PL, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 512.0, group: "Goblintower" },
    LocationConfig { prefab: "StoneTower1", label: "Stone Tower", kind: Kind::Fortress,
        biome: PL, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 14.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 512.0, group: "Goblintower" },
    LocationConfig { prefab: "StoneTower3", label: "Stone Tower", kind: Kind::Fortress,
        biome: PL, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 14.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 512.0, group: "Goblintower" },
    LocationConfig { prefab: "Mistlands_Harbour1", label: "Harbour", kind: Kind::Village,
        biome: ML, biome_area: 1, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 2.0, max_terrain_delta: 20.0, min_distance_from_similar: 64.0, group: "Harbour" },
    LocationConfig { prefab: "Mistlands_Viaduct1", label: "Viaduct", kind: Kind::Monument,
        biome: ML, biome_area: 2, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 24.00,
        min_terrain_delta: 2.0, max_terrain_delta: 40.0, min_distance_from_similar: 128.0, group: "Harbour" },
    LocationConfig { prefab: "Mistlands_Viaduct2", label: "Viaduct", kind: Kind::Monument,
        biome: ML, biome_area: 2, quantity: 150, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 4.0, max_terrain_delta: 40.0, min_distance_from_similar: 64.0, group: "Harbour" },
    LocationConfig { prefab: "IcePond1", label: "Ice Pond", kind: Kind::Resource,
        biome: DN, biome_area: 2, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 10.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 0.0, max_terrain_delta: 1.5, min_distance_from_similar: 128.0, group: "icepond" },
    LocationConfig { prefab: "NorthMemorialPlace", label: "North Memorial Place", kind: Kind::Monument,
        biome: DN, biome_area: 2, quantity: 15, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 25.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 400.0, group: "memorialplace" },
    LocationConfig { prefab: "MorgenHole1", label: "Morgen Hole", kind: Kind::Cave,
        biome: AL, biome_area: 2, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 300.0, group: "MorgenHole" },
    LocationConfig { prefab: "MorgenHole2", label: "Morgen Hole", kind: Kind::Cave,
        biome: AL, biome_area: 2, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 200.0, group: "MorgenHole" },
    LocationConfig { prefab: "MorgenHole3", label: "Morgen Hole", kind: Kind::Cave,
        biome: AL, biome_area: 2, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 200.0, group: "MorgenHole" },
    LocationConfig { prefab: "MorkBorg", label: "Mork Borg", kind: Kind::Mystery,
        biome: DN, biome_area: 3, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 30.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 30.00,
        min_terrain_delta: 0.0, max_terrain_delta: 300.0, min_distance_from_similar: 275.0, group: "morkborg" },
    LocationConfig { prefab: "MountainCave02", label: "Frost Cave", kind: Kind::Cave,
        biome: MT, biome_area: 3, quantity: 120, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 1.00, exterior_radius: 15.00,
        min_terrain_delta: 0.0, max_terrain_delta: 40.0, min_distance_from_similar: 200.0, group: "mountaincaves" },
    LocationConfig { prefab: "StoneTowerRuins04", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: MT, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 150.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.28,
        min_terrain_delta: 6.0, max_terrain_delta: 40.0, min_distance_from_similar: 128.0, group: "Mountainruin" },
    LocationConfig { prefab: "StoneTowerRuins05", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: MT, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 150.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 22.00,
        min_terrain_delta: 6.0, max_terrain_delta: 40.0, min_distance_from_similar: 128.0, group: "Mountainruin" },
    LocationConfig { prefab: "DN_hut01", label: "Hut", kind: Kind::Village,
        biome: DN, biome_area: 2, quantity: 40, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 40.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 100.0, group: "northvillage" },
    LocationConfig { prefab: "Runestone_Greydwarfs", label: "Greydwarfs", kind: Kind::Runestone,
        biome: BF, biome_area: 3, quantity: 25, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 99.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "Runestone_Draugr", label: "Draugr", kind: Kind::Runestone,
        biome: SW, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.5, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "DrakeLorestone", label: "Drake Lorestone", kind: Kind::Runestone,
        biome: MT, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 4.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "Runestone_Boars", label: "Boars", kind: Kind::Runestone,
        biome: M, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "Runestone_BlackForest", label: "Black Forest", kind: Kind::Runestone,
        biome: BF, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "Runestone_Mistlands", label: "Mistlands", kind: Kind::Runestone,
        biome: ML, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "Runestone_Ashlands", label: "Ashlands", kind: Kind::Runestone,
        biome: AL, biome_area: 3, quantity: 70, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "Runestone_DeepNorth", label: "Deep North", kind: Kind::Runestone,
        biome: DN, biome_area: 3, quantity: 70, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "Runestone_Meadows", label: "Meadows", kind: Kind::Runestone,
        biome: M, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "Runestone_Swamps", label: "Swamps", kind: Kind::Runestone,
        biome: SW, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "Runestone_Mountains", label: "Mountains", kind: Kind::Runestone,
        biome: MT, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 100.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "Runestone_Plains", label: "Plains", kind: Kind::Runestone,
        biome: PL, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Runestones" },
    LocationConfig { prefab: "ShipSetting03", label: "Ship Setting", kind: Kind::Monument,
        biome: DN, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 0.50, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 64.0, group: "shipsetting" },
    LocationConfig { prefab: "ShipSetting02", label: "Ship Setting", kind: Kind::Monument,
        biome: DN, biome_area: 3, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 0.50, exterior_radius: 24.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 64.0, group: "shipsetting" },
    LocationConfig { prefab: "ShipWreck01", label: "Ship Wreck", kind: Kind::Wreck,
        biome: SW|BF|PL|OC, biome_area: 3, quantity: 25, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 1024.0, group: "Shipwreck" },
    LocationConfig { prefab: "ShipWreck02", label: "Ship Wreck", kind: Kind::Wreck,
        biome: SW|BF|PL|OC, biome_area: 3, quantity: 25, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 1024.0, group: "Shipwreck" },
    LocationConfig { prefab: "ShipWreck03", label: "Ship Wreck", kind: Kind::Wreck,
        biome: SW|BF|PL|OC, biome_area: 3, quantity: 25, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 1024.0, group: "Shipwreck" },
    LocationConfig { prefab: "ShipWreck04", label: "Ship Wreck", kind: Kind::Wreck,
        biome: SW|BF|PL|OC, biome_area: 3, quantity: 25, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 14.00,
        min_terrain_delta: 0.0, max_terrain_delta: 10.0, min_distance_from_similar: 1024.0, group: "Shipwreck" },
    LocationConfig { prefab: "StoneHenge1", label: "Stone Henge", kind: Kind::Monument,
        biome: PL, biome_area: 3, quantity: 5, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 30.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 1000.0, group: "Stonehenge" },
    LocationConfig { prefab: "StoneHenge2", label: "Stone Henge", kind: Kind::Monument,
        biome: PL, biome_area: 3, quantity: 5, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 30.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 1000.0, group: "Stonehenge" },
    LocationConfig { prefab: "StoneHenge3", label: "Stone Henge", kind: Kind::Monument,
        biome: PL, biome_area: 3, quantity: 5, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 30.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 1000.0, group: "Stonehenge" },
    LocationConfig { prefab: "StoneHenge4", label: "Stone Henge", kind: Kind::Monument,
        biome: PL, biome_area: 3, quantity: 5, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 30.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 1000.0, group: "Stonehenge" },
    LocationConfig { prefab: "StoneHenge5", label: "Stone Henge", kind: Kind::Monument,
        biome: PL, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 16.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 500.0, group: "Stonehenge" },
    LocationConfig { prefab: "StoneHenge6", label: "Stone Henge", kind: Kind::Monument,
        biome: PL, biome_area: 3, quantity: 20, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 16.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 500.0, group: "Stonehenge" },
    LocationConfig { prefab: "StoneTowerRuins03", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 80, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 9.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 200.0, group: "Stonetowerruins" },
    LocationConfig { prefab: "StoneTowerRuins07", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 80, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 9.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 200.0, group: "Stonetowerruins" },
    LocationConfig { prefab: "StoneTowerRuins08", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 80, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 9.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 200.0, group: "Stonetowerruins" },
    LocationConfig { prefab: "StoneTowerRuins09", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 80, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 7.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 200.0, group: "Stonetowerruins" },
    LocationConfig { prefab: "StoneTowerRuins10", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 80, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 7.00,
        min_terrain_delta: 0.0, max_terrain_delta: 2.0, min_distance_from_similar: 200.0, group: "Stonetowerruins" },
    LocationConfig { prefab: "StoneTowerRuins07_sunk", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 10, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -8.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 2.00, exterior_radius: 7.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 50.0, group: "Stonetowerruins_sunk" },
    LocationConfig { prefab: "StoneTowerRuins08_sunk", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 10, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -8.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 2.00, exterior_radius: 7.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 50.0, group: "Stonetowerruins_sunk" },
    LocationConfig { prefab: "StoneTowerRuins09_sunk", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 10, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -8.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 2.00, exterior_radius: 7.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 50.0, group: "Stonetowerruins_sunk" },
    LocationConfig { prefab: "StoneTowerRuins10_sunk", label: "Stone Tower Ruins", kind: Kind::Ruin,
        biome: BF, biome_area: 3, quantity: 10, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -8.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 0.00, forest_max: 2.00, exterior_radius: 7.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 50.0, group: "Stonetowerruins_sunk" },
    LocationConfig { prefab: "SwampHut5", label: "Swamp Hut", kind: Kind::Village,
        biome: SW, biome_area: 3, quantity: 25, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Swamphut" },
    LocationConfig { prefab: "SwampHut1", label: "Swamp Hut", kind: Kind::Village,
        biome: SW, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Swamphut" },
    LocationConfig { prefab: "SwampHut2", label: "Swamp Hut", kind: Kind::Village,
        biome: SW, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Swamphut" },
    LocationConfig { prefab: "SwampHut3", label: "Swamp Hut", kind: Kind::Village,
        biome: SW, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 2.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Swamphut" },
    LocationConfig { prefab: "SwampHut4", label: "Swamp Hut", kind: Kind::Village,
        biome: SW, biome_area: 3, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 8.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 128.0, group: "Swamphut" },
    LocationConfig { prefab: "SwampRuin1", label: "Swamp Ruin", kind: Kind::Ruin,
        biome: SW, biome_area: 2, quantity: 30, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -0.5, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 12.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 256.0, group: "SwampRuin" },
    LocationConfig { prefab: "SwampRuin2", label: "Swamp Ruin", kind: Kind::Ruin,
        biome: SW, biome_area: 2, quantity: 30, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -0.5, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 10.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 256.0, group: "SwampRuin" },
    LocationConfig { prefab: "TarPit2", label: "Tar Pit", kind: Kind::Resource,
        biome: PL, biome_area: 2, quantity: 16, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 25.00,
        min_terrain_delta: 0.0, max_terrain_delta: 1.5, min_distance_from_similar: 128.0, group: "tarpit" },
    LocationConfig { prefab: "TarPit1", label: "Tar Pit", kind: Kind::Resource,
        biome: PL, biome_area: 2, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 20.00,
        min_terrain_delta: 0.0, max_terrain_delta: 1.5, min_distance_from_similar: 128.0, group: "tarpit" },
    LocationConfig { prefab: "TarPit3", label: "Tar Pit", kind: Kind::Resource,
        biome: PL, biome_area: 2, quantity: 100, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 5.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 14.00,
        min_terrain_delta: 0.0, max_terrain_delta: 1.5, min_distance_from_similar: 128.0, group: "tarpit" },
    LocationConfig { prefab: "LumberCamp", label: "Lumber Camp", kind: Kind::Mine,
        biome: DN, biome_area: 2, quantity: 50, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 4.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 3.0, min_distance_from_similar: 100.0, group: "thehole" },
    LocationConfig { prefab: "CharredTowerRuins1", label: "Charred Tower Ruins", kind: Kind::Ruin,
        biome: AL, biome_area: 3, quantity: 30, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 22.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 100.0, group: "towerruins" },
    LocationConfig { prefab: "CharredTowerRuins1_dvergr", label: "Charred Tower Ruins", kind: Kind::Ruin,
        biome: AL, biome_area: 3, quantity: 30, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: 0.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 22.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 100.0, group: "towerruins" },
    LocationConfig { prefab: "WoodFarm1", label: "Wood Farm", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 10, prioritized: false, center_first: false,
        unique: false, min_distance: 500.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 128.0, group: "woodvillage" },
    LocationConfig { prefab: "WoodVillage1", label: "Wood Village", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 15, prioritized: false, center_first: false,
        unique: false, min_distance: 2000.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 256.0, group: "woodvillage" },
    LocationConfig { prefab: "WoodVillage2", label: "Wood Village", kind: Kind::Village,
        biome: M, biome_area: 3, quantity: 15, prioritized: false, center_first: false,
        unique: false, min_distance: 2000.0, max_distance: 0.0, min_altitude: 1.0, max_altitude: 1000.0,
        in_forest: false, forest_min: 0.00, forest_max: 1.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 4.0, min_distance_from_similar: 256.0, group: "woodvillage" },
    LocationConfig { prefab: "CharredRuins1", label: "Charred Ruins", kind: Kind::Ruin,
        biome: AL, biome_area: 2, quantity: 75, prioritized: false, center_first: false,
        unique: false, min_distance: 0.0, max_distance: 0.0, min_altitude: -5.0, max_altitude: 1000.0,
        in_forest: true, forest_min: 1.00, forest_max: 5.00, exterior_radius: 32.00,
        min_terrain_delta: 0.0, max_terrain_delta: 6.0, min_distance_from_similar: 256.0, group: "zigg" },
];

pub struct Placed {
    pub cfg: usize,
    pub x: f32,
    pub y: f32,
}

#[inline]
fn zone_pos(z: (i32, i32)) -> (f32, f32) {
    (z.0 as f32 * ZONE_SIZE, z.1 as f32 * ZONE_SIZE)
}

/// `GetRandomZone` — rejects zones outside the world, consuming draws each try.
fn random_zone(rng: &mut UnityRandom, range: f32) -> (i32, i32) {
    let num = (range as i32) / 64;
    loop {
        let z = (rng.range_i32(-num, num), rng.range_i32(-num, num));
        let p = zone_pos(z);
        if (p.0 * p.0 + p.1 * p.1).sqrt() < 10000.0 {
            return z;
        }
        // num == 0 can only ever produce (0,0), which is inside the world, so
        // this loop always terminates.
    }
}

fn random_point_in_zone(rng: &mut UnityRandom, z: (i32, i32), radius: f32) -> (f32, f32) {
    let zp = zone_pos(z);
    let x = rng.range_f32(-32.0 + radius, 32.0 - radius);
    let y = rng.range_f32(-32.0 + radius, 32.0 - radius);
    (zp.0 + x, zp.1 + y)
}

/// Median when a zone and all eight neighbours share a biome, Edge otherwise.
/// Zone coordinates never leave +/-157 (the world disc is 10 km and zones are
/// 64 m), so the per-zone caches are flat arrays rather than hash maps. This
/// loop runs tens of millions of times per world; hashing a tuple each time
/// was a large share of placement cost.
pub const ZONE_HALF: i32 = 192;
pub const ZONE_DIM: usize = (ZONE_HALF * 2 + 1) as usize;

/// Heightmap.Biome flag back to the enum. 0 means "not cached yet".
#[inline(always)]
fn from_bits(v: u16) -> Biome {
    match v {
        1 => Biome::Meadows,
        2 => Biome::Swamp,
        4 => Biome::Mountain,
        8 => Biome::BlackForest,
        16 => Biome::Plains,
        32 => Biome::AshLands,
        64 => Biome::DeepNorth,
        256 => Biome::Ocean,
        512 => Biome::Mistlands,
        _ => Biome::None,
    }
}

#[inline(always)]
fn zone_index(z: (i32, i32)) -> Option<usize> {
    if z.0 < -ZONE_HALF || z.0 > ZONE_HALF || z.1 < -ZONE_HALF || z.1 > ZONE_HALF {
        return None;
    }
    Some(((z.1 + ZONE_HALF) as usize) * ZONE_DIM + (z.0 + ZONE_HALF) as usize)
}

fn biome_area(wg: &WorldGenerator, cache: &mut [u16], z: (i32, i32)) -> u8 {
    let mut at = |zz: (i32, i32)| -> Biome {
        let Some(i) = zone_index(zz) else {
            let p = zone_pos(zz);
            return wg.biome(p.0, p.1);
        };
        if cache[i] != 0 {
            return from_bits(cache[i]);
        }
        let p = zone_pos(zz);
        let b = wg.biome(p.0, p.1);
        cache[i] = b as u16;
        b
    };
    let centre = at(z);
    for dy in -1..=1i32 {
        for dx in -1..=1i32 {
            if dx == 0 && dy == 0 {
                continue;
            }
            if at((z.0 + dx, z.1 + dy)) != centre {
                return 1; // Edge
            }
        }
    }
    2 // Median
}

/// The key a location competes with itself under: its group if it has one,
/// otherwise its own prefab. `m_minDistanceFromSimilar` only ever compares
/// within this set.
fn similar_key(cfg_i: usize) -> &'static str {
    let cfg = &LOCATIONS[cfg_i];
    if cfg.group.is_empty() { cfg.prefab } else { cfg.group }
}

fn have_in_range(similar: &[(f32, f32)], p: (f32, f32), radius: f32) -> bool {
    let r2 = radius * radius;
    similar
        .iter()
        .any(|&(x, y)| (x - p.0) * (x - p.0) + (y - p.1) * (y - p.1) < r2)
}

/// Runs the full placement pass for a world. One-time per seed.
/// Resumable placement state.
///
/// Placement cannot be parallelised or reordered — there is one shared
/// occupancy map, one location per 64 m zone across *all* types, and
/// prioritised types claim zones first — so the only way to show progress is
/// to run it type by type and hand back what has been placed so far.
///
/// That is safe to display: once a type has been processed its placements are
/// final, because later types can only be blocked by earlier ones, never the
/// other way round.
pub struct GenState {
    order: Vec<usize>,
    next: usize,
    /// One bit per zone, flat — the game allows one location per 64 m zone
    /// across every type, so this is checked on every single attempt.
    occupied: Vec<bool>,
    zone_cache: Vec<u16>,
    /// Placed positions bucketed by `similar_key`, so the
    /// min-distance-from-similar test scans tens of entries instead of the
    /// whole 12 000-location list.
    similar: HashMap<&'static str, Vec<(f32, f32)>>,
    pub placed: Vec<Placed>,
}

impl GenState {
    pub fn progress(&self) -> f32 {
        self.next as f32 / self.order.len() as f32
    }
    pub fn done(&self) -> bool {
        self.next >= self.order.len()
    }
}

pub fn begin() -> GenState {
    // Prioritised types claim zones first; stable within each tier.
    let mut order: Vec<usize> = (0..LOCATIONS.len()).collect();
    order.sort_by_key(|&i| !LOCATIONS[i].prioritized);
    GenState {
        order,
        next: 0,
        occupied: vec![false; ZONE_DIM * ZONE_DIM],
        zone_cache: vec![0u16; ZONE_DIM * ZONE_DIM],
        similar: HashMap::new(),
        placed: Vec::new(),
    }
}

/// Places up to `types` more location types. Returns true when finished.
pub fn step(wg: &WorldGenerator, st: &mut GenState, types: usize) -> bool {
    let end = (st.next + types).min(st.order.len());
    while st.next < end {
        let ci = st.order[st.next];
        st.next += 1;
        let occupied = &mut st.occupied;
        let zone_cache = &mut st.zone_cache;
        let placed = &mut st.placed;
        let similar_bucket = st.similar.entry(similar_key(ci)).or_default();

    let cfg = &LOCATIONS[ci];
    // Each type gets its own independent stream.
    let mut rng = UnityRandom::new(wg.seed.wrapping_add(stable_hash_code(cfg.prefab)));
    let radius = cfg.exterior_radius;
    let mut count = 0i32;
    let mut max_range = if cfg.center_first { cfg.min_distance } else { 10000.0 };
    let cap = if cfg.prioritized { 200_000 } else { 100_000 };
    let mut attempts = 0;

    while attempts < cap && count < cfg.quantity {
        let zone = random_zone(&mut rng, max_range);
        if cfg.center_first {
            max_range += 1.0;
        }
        let zi = zone_index(zone);
        if !zi.is_some_and(|i| occupied[i]) {
            let area = biome_area(wg, zone_cache, zone);
            if cfg.biome_area & area != 0 {
                for _ in 0..20 {
                    let p = random_point_in_zone(&mut rng, zone, radius);
                    let mag = (p.0 * p.0 + p.1 * p.1).sqrt();
                    if cfg.min_distance != 0.0 && mag < cfg.min_distance {
                        continue;
                    }
                    if cfg.max_distance != 0.0 && mag > cfg.max_distance {
                        continue;
                    }
                    let (b, base) = wg.biome_with_base(p.0, p.1);
                    if cfg.biome & (b as u16) == 0 {
                        continue;
                    }
                    let y = wg.biome_height_with_base(b, p.0, p.1, base);
                    let alt = y - WATER_LEVEL;
                    if alt < cfg.min_altitude || alt > cfg.max_altitude {
                        continue;
                    }
                    if cfg.in_forest {
                        let ff = wg.forest_factor(p.0, p.1);
                        if ff < cfg.forest_min || ff > cfg.forest_max {
                            continue;
                        }
                    }
                    // Consumes 20 RNG values; only reached past the checks above.
                    let delta = wg.terrain_delta(p.0, p.1, radius, &mut rng);
                    if delta > cfg.max_terrain_delta || delta < cfg.min_terrain_delta {
                        continue;
                    }
                    if cfg.min_distance_from_similar > 0.0
                        && have_in_range(similar_bucket, p, cfg.min_distance_from_similar)
                    {
                        continue;
                    }
                    if let Some(i) = zi {
                        occupied[i] = true;
                    }
                    similar_bucket.push(p);
                    placed.push(Placed { cfg: ci, x: p.0, y: p.1 });
                    count += 1;
                    break;
                }
            }
        }
        attempts += 1;
    }
    }
    st.done()
}

pub fn generate(wg: &WorldGenerator) -> Vec<Placed> {
    let mut st = begin();
    while !step(wg, &mut st, 32) {}
    st.placed
}

