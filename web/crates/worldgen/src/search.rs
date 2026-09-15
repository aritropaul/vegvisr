//! Seed search.
//!
//! Nobody else does this with exact data. The most popular Valheim seed finder
//! scores biome composition only and lists POI filtering as unbuilt; the other
//! one launches a real Valheim dedicated server per seed, about a minute each.
//!
//! The cost structure here makes a funnel obvious, and it was measured rather
//! than assumed:
//!
//! | stage                        | per seed | what it can answer            |
//! |------------------------------|----------|-------------------------------|
//! | biome grid, no pregeneration | ~1 ms    | which biomes are near spawn   |
//! | + river/lake pregeneration   | ~145 ms  | where the water actually is   |
//! | + landmass connectivity      | ~55 ms   | what you can walk to          |
//! | + location placement         | ~7 s     | where the bosses are          |
//!
//! Biome classification never touches river data — verified over 125 627
//! samples, bit-identical with and without — so the first stage can skip
//! pregeneration entirely and run ~120x faster than a full world build. Most
//! candidates die there.

use crate::connect;
use crate::geo::{Biome, WorldGenerator};

/// Characters used to build candidate phrases.
///
/// Deliberately excludes `0 O o 1 l I` — those are the pairs that make people
/// mistype a shared seed and conclude the map tool is broken. A seed this
/// search hands out cannot be misread.
const ALPHABET: &[u8] = b"23456789abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ";

/// Deterministic phrase for an index, so a search is reproducible and can be
/// resumed across batches without keeping state.
pub fn phrase_for(index: u32) -> String {
    // SplitMix64 finalizer: cheap, and scatters consecutive indices so that
    // adjacent batches don't explore adjacent-looking phrases.
    let mut z = (index as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^= z >> 31;
    let n = ALPHABET.len() as u64;
    let mut out = String::with_capacity(10);
    for _ in 0..10 {
        out.push(ALPHABET[(z % n) as usize] as char);
        z /= n;
        // Re-stir once the entropy runs low.
        if z < n {
            z = z
                .wrapping_mul(0x9E37_79B9_7F4A_7C15)
                .wrapping_add(index as u64 + 1);
        }
    }
    out
}

#[derive(Clone, Copy)]
pub struct Criteria {
    /// Radius around spawn the cheap stage looks at.
    pub radius: f32,
    /// Biome bitmask that must all appear within `radius` of spawn.
    pub required_near_spawn: u16,
    /// Minimum area of the landmass containing spawn, in km².
    pub min_home_km2: f32,
    /// Biome bitmask that must all appear *on* the spawn landmass.
    pub required_on_home: u16,
}

pub struct Hit {
    pub phrase: String,
    pub seed: i32,
    pub home_km2: f32,
    pub biomes_on_home: u16,
}

/// Stage one: biomes near spawn, no pregeneration.
///
/// Samples a coarse polar-ish lattice rather than a dense grid — the question
/// is only "does this biome occur near spawn at all", and a 24x24 grid over
/// the radius answers it for a fraction of the cost.
fn near_spawn_biomes(wg: &WorldGenerator, radius: f32) -> u16 {
    let mut mask = 0u16;
    const N: i32 = 24;
    for j in -N..=N {
        for i in -N..=N {
            let wx = (i as f32 / N as f32) * radius;
            let wy = (j as f32 / N as f32) * radius;
            if (wx * wx + wy * wy).sqrt() > radius {
                continue;
            }
            mask |= wg.biome(wx, wy) as u16;
        }
    }
    mask
}

/// Runs the whole funnel for one candidate. Returns `None` as soon as a stage
/// rejects, so the expensive stages only ever see survivors.
pub fn evaluate(index: u32, c: &Criteria) -> Option<Hit> {
    let phrase = phrase_for(index);
    let seed = crate::random::seed_from_name(&phrase);

    // Stage 1 — no rivers, no lakes, no streams.
    let cheap = WorldGenerator::biome_only(seed, 2);
    let near = near_spawn_biomes(&cheap, c.radius);
    if c.required_near_spawn & !near != 0 {
        return None;
    }
    if c.min_home_km2 <= 0.0 && c.required_on_home == 0 {
        return Some(Hit { phrase, seed, home_km2: 0.0, biomes_on_home: near });
    }

    // Stage 2 — the real world, so water is where the game puts it. Only the
    // spawn landmass is flooded; the full component labelling costs ~55 ms and
    // answers questions this does not ask.
    let wg = WorldGenerator::from_seed(seed, 2);
    let home_km2 = connect::home_area_km2(&wg);
    if home_km2 < c.min_home_km2 {
        return None;
    }

    let mut on_home = 0u16;
    if c.required_on_home != 0 {
        let lm = connect::build(&wg);
        // Sample the home landmass itself rather than a disc around spawn: the
        // point of the question is what you can reach without a boat.
        const N: i32 = 90;
        let step = crate::geo::WORLD_SIZE / N as f32;
        for j in -N..=N {
            for i in -N..=N {
                let wx = i as f32 * step;
                let wy = j as f32 * step;
                if lm.at(wx, wy) != lm.spawn {
                    continue;
                }
                on_home |= wg.biome(wx, wy) as u16;
            }
        }
        if c.required_on_home & !on_home != 0 {
            return None;
        }
    }

    Some(Hit { phrase, seed, home_km2, biomes_on_home: on_home })
}

/// Biome bit for a name, so the UI can build masks without duplicating the
/// enum's discriminants.
pub fn biome_bit(name: &str) -> u16 {
    match name {
        "Meadows" => Biome::Meadows as u16,
        "Swamp" => Biome::Swamp as u16,
        "Mountain" => Biome::Mountain as u16,
        "BlackForest" => Biome::BlackForest as u16,
        "Plains" => Biome::Plains as u16,
        "AshLands" => Biome::AshLands as u16,
        "DeepNorth" => Biome::DeepNorth as u16,
        "Ocean" => Biome::Ocean as u16,
        "Mistlands" => Biome::Mistlands as u16,
        _ => 0,
    }
}
