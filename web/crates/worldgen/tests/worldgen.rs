//! Regression guards for the world generator.

use worldgen::geo::{Biome, WorldGenerator};

/// The seed everything is developed and checked against.
const TEST_SEED: &str = "j3QV2ftr3y";
use worldgen::random::seed_from_name;

fn distribution(wg: &WorldGenerator, n: usize) -> [f32; 10] {
    let mut counts = [0usize; 10];
    let mut total = 0usize;
    let span = 20000.0f32;
    for py in 0..n {
        for px in 0..n {
            let wx = (px as f32 / n as f32) * span - 10000.0;
            let wy = (py as f32 / n as f32) * span - 10000.0;
            if (wx * wx + wy * wy).sqrt() > 10000.0 {
                continue;
            }
            total += 1;
            let i = match wg.biome(wx, wy) {
                Biome::None => 0,
                Biome::Meadows => 1,
                Biome::Swamp => 2,
                Biome::Mountain => 3,
                Biome::BlackForest => 4,
                Biome::Plains => 5,
                Biome::AshLands => 6,
                Biome::DeepNorth => 7,
                Biome::Ocean => 8,
                Biome::Mistlands => 9,
            };
            counts[i] += 1;
        }
    }
    let mut out = [0.0f32; 10];
    for i in 0..10 {
        out[i] = counts[i] as f32 / total as f32 * 100.0;
    }
    out
}

#[test]
fn seed_name_maps_to_world_seed() {
    assert_eq!(seed_from_name("Dedbtjdcv"), 1218100378);
    assert_eq!(seed_from_name(TEST_SEED), -647823732);
    // Valheim special-cases the empty seed to 0 rather than hashing it.
    assert_eq!(seed_from_name(""), 0);
}

#[test]
fn offsets_are_drawn_in_the_documented_order() {
    let wg = WorldGenerator::from_seed_name("Dedbtjdcv", 2);
    assert_eq!(
        [wg.offset0, wg.offset1, wg.offset2, wg.offset3, wg.offset4],
        [-8087.0, 9698.0, -4921.0, -8635.0, -116.0]
    );
    assert_eq!(wg.river_seed, 1741748534);
    assert_eq!(wg.stream_seed, -2141061776);
}

/// Ashlands occupies a fixed southern band, independently measured by the
/// community at ~9.5% of world area and identical across seeds. Mistlands
/// varies with seed, measured in the 18.4-19.5% range.
#[test]
fn biome_distribution_matches_independent_measurements() {
    for seed in [TEST_SEED, "Valheim", "Dedbtjdcv"] {
        let wg = WorldGenerator::from_seed_name(seed, 2);
        let d = distribution(&wg, 384);
        let ash = d[6];
        assert!(
            (ash - 9.5).abs() < 1.0,
            "seed {seed}: Ashlands {ash:.2}% should sit near the measured 9.5%"
        );
        let mist = d[9];
        assert!(
            (16.0..22.0).contains(&mist),
            "seed {seed}: Mistlands {mist:.2}% outside the measured band"
        );
        // Spawn is always Meadows-adjacent land, never ocean.
        assert_ne!(wg.biome(0.0, 0.0), Biome::Ocean);
    }
}

#[test]
fn generation_is_deterministic() {
    let a = WorldGenerator::from_seed_name(TEST_SEED, 2);
    let b = WorldGenerator::from_seed_name(TEST_SEED, 2);
    for &(x, y) in &[(0.0, 0.0), (1234.0, -5678.0), (-9000.0, 2000.0), (300.5, 77.25)] {
        assert_eq!(a.biome(x, y), b.biome(x, y), "biome mismatch at {x},{y}");
        assert_eq!(a.height(x, y), b.height(x, y), "height mismatch at {x},{y}");
    }
}

#[test]
fn different_seeds_produce_different_worlds() {
    let a = WorldGenerator::from_seed_name(TEST_SEED, 2);
    let b = WorldGenerator::from_seed_name("Valheim", 2);
    let mut differences = 0;
    for i in 0..200 {
        let x = (i as f32 * 37.0) % 8000.0 - 4000.0;
        let y = (i as f32 * 91.0) % 8000.0 - 4000.0;
        if a.biome(x, y) != b.biome(x, y) {
            differences += 1;
        }
    }
    assert!(differences > 50, "expected seeds to diverge, got {differences}/200");
}

/// Ashlands is south (-y) and Deep North is north (+y); neither should ever
/// appear on the opposite pole.
#[test]
fn poles_are_oriented_correctly() {
    let wg = WorldGenerator::from_seed_name(TEST_SEED, 2);
    assert_eq!(wg.biome(0.0, -9800.0), Biome::AshLands);
    assert_ne!(wg.biome(0.0, 9800.0), Biome::AshLands);
    let north = wg.biome(0.0, 9800.0);
    assert!(
        north == Biome::DeepNorth || north == Biome::Mountain || north == Biome::Ocean,
        "north pole resolved to {north:?}"
    );
}

/// The world is a disc; past the water edge everything drops to the floor.
#[test]
fn beyond_the_world_edge_is_sunken() {
    let wg = WorldGenerator::from_seed_name(TEST_SEED, 2);
    assert!(wg.height(11000.0, 0.0) < 0.0);
}

// ── point-of-interest placement ───────────────────────────────────────────

/// Every configured location type must actually place something. A type that
/// silently places zero usually means an impossible constraint combination
/// (e.g. a max-distance smaller than where its biome starts).
///
/// Deep North types are exempt and checked separately: several of them require
/// real altitude (`DN_Bossroom` wants 80 m) and this port still generates the
/// pre-1.0 placeholder Deep North terrain, which never gets that high. Their
/// placement parameters are correct; the ground under them is not yet.
#[test]
fn every_location_type_places_at_least_one() {
    use worldgen::geo::Biome;
    use worldgen::locations::{self, LOCATIONS};
    let wg = WorldGenerator::from_seed_name(TEST_SEED, 2);
    let placed = locations::generate(&wg);
    let mut empty = Vec::new();
    let mut empty_deep_north = Vec::new();
    for (i, cfg) in LOCATIONS.iter().enumerate() {
        let n = placed.iter().filter(|p| p.cfg == i).count();
        if n == 0 {
            if cfg.biome == Biome::DeepNorth as u16 {
                empty_deep_north.push(cfg.prefab);
            } else {
                empty.push(cfg.prefab);
            }
            continue;
        }
        assert!(
            n <= cfg.quantity as usize,
            "{} placed {} above its quantity {}",
            cfg.prefab, n, cfg.quantity
        );
    }
    assert!(empty.is_empty(), "placed nothing: {empty:?}");
    // Pin the known shortfall so it cannot quietly grow.
    assert!(
        empty_deep_north.len() <= 4,
        "more Deep North types are failing to place than the terrain gap explains: {empty_deep_north:?}"
    );
}


/// Placement must respect the biome mask and distance bands it was given.
#[test]
fn locations_respect_their_constraints() {
    use worldgen::locations::{self, LOCATIONS};
    let wg = WorldGenerator::from_seed_name(TEST_SEED, 2);
    for p in locations::generate(&wg) {
        let cfg = &LOCATIONS[p.cfg];
        let b = wg.biome(p.x, p.y) as u16;
        assert!(cfg.biome & b != 0, "{} placed in wrong biome {:?}", cfg.prefab, b);
        let d = (p.x * p.x + p.y * p.y).sqrt();
        if cfg.min_distance != 0.0 {
            assert!(d >= cfg.min_distance, "{} too close: {d}", cfg.prefab);
        }
        if cfg.max_distance != 0.0 {
            assert!(d <= cfg.max_distance, "{} too far: {d}", cfg.prefab);
        }
        assert!(d < 10500.0, "{} outside the world", cfg.prefab);
    }
}

/// One location per 64 m zone, globally, across all types.
#[test]
fn locations_never_share_a_zone() {
    use std::collections::HashSet;
    use worldgen::locations::{self, ZONE_SIZE};
    let wg = WorldGenerator::from_seed_name(TEST_SEED, 2);
    let mut zones = HashSet::new();
    for p in locations::generate(&wg) {
        let z = (
            ((p.x + 32.0) / ZONE_SIZE).floor() as i32,
            ((p.y + 32.0) / ZONE_SIZE).floor() as i32,
        );
        assert!(zones.insert(z), "two locations share zone {z:?}");
    }
}

// ── rendering fidelity ────────────────────────────────────────────────────

/// Every land pixel should be painted its own biome's colour, not its
/// neighbours'. The boundary blend may mix hues only in a narrow transition
/// band; if the blend is wider than the biome patches themselves, regions get
/// averaged away and the map stops matching the classification underneath.
///
/// Deliberately measured over ALL land pixels rather than region interiors:
/// an interiors-only check passes even with a wildly over-wide blend, because
/// interiors are protected separately.
#[test]
fn biome_fill_matches_classification() {
    use worldgen::geo::Biome;
    use worldgen::render::{Mode, Palette, TileRenderer};

    let wg = WorldGenerator::from_seed_name(TEST_SEED, 2);
    let mut tr = TileRenderer::new(wg);
    const N: usize = 256;
    // A mid-zoom tile, where biome patches are only tens of pixels across —
    // the regime where an over-wide blend does its damage.
    let span = 4000.0f32;
    let (ox, oy) = (-2000.0f32, 2000.0f32);
    tr.render(ox, oy, span, N, Mode::Biome, Palette::Classic);

    let step = span / N as f32;
    let px = tr.pixels().to_vec();

    let mut checked = 0;
    let mut mismatched = 0;
    for j in 0..N {
        for i in 0..N {
            let wx = ox + i as f32 * step;
            let wy = oy - j as f32 * step;
            let b = tr.wg.biome(wx, wy);
            if b == Biome::Ocean || b == Biome::None {
                continue;
            }
            // Skip the waterline, where the shore stroke legitimately tints.
            let h = tr.wg.height(wx, wy);
            if h < 42.0 {
                continue;
            }

            let o = (j * N + i) * 4;
            let got = [px[o] as f32, px[o + 1] as f32, px[o + 2] as f32];
            // Compare direction, not magnitude: shading scales the ink.
            let want = expected_ink(b);
            let dot = got[0] * want[0] + got[1] * want[1] + got[2] * want[2];
            let gl = (got[0] * got[0] + got[1] * got[1] + got[2] * got[2]).sqrt();
            let wl = (want[0] * want[0] + want[1] * want[1] + want[2] * want[2]).sqrt();
            if gl < 1.0 || wl < 1.0 {
                continue;
            }
            checked += 1;
            if dot / (gl * wl) < 0.98 {
                mismatched += 1;
            }
        }
    }

    assert!(checked > 2000, "not enough land samples: {checked}");
    let ratio = mismatched as f32 / checked as f32;
    assert!(
        ratio < 0.12,
        "{mismatched}/{checked} land pixels ({:.1}%) do not match their biome",
        ratio * 100.0
    );
}

/// Mirrors the renderer's Classic ink table.
fn expected_ink(b: worldgen::geo::Biome) -> [f32; 3] {
    use worldgen::geo::Biome::*;
    match b {
        Meadows => [168.0, 224.0, 95.0],
        BlackForest => [47.0, 125.0, 79.0],
        Swamp => [154.0, 123.0, 69.0],
        Plains => [217.0, 184.0, 118.0],
        Mountain => [220.0, 233.0, 242.0],
        Mistlands => [138.0, 123.0, 200.0],
        AshLands => [224.0, 85.0, 47.0],
        DeepNorth => [159.0, 216.0, 240.0],
        Ocean => [38.0, 84.0, 196.0],
        None => [120.0, 120.0, 120.0],
    }
}
