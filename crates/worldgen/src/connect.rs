//! Landmass connectivity.
//!
//! Valheim players do not judge a seed by how far a boss is. They judge it by
//! whether the boss is *on the same island as spawn* — "4 bosses, 5 biomes and
//! 2 traders on the starting continent" is the standard way a good seed gets
//! described, and the standard complaint is a boss that is close on the map but
//! walled off behind open ocean. Straight-line distance cannot answer either.
//!
//! So: rasterise the world into land/water cells, label connected components,
//! and record which component each point falls in. Everything the seed report
//! needs — is this reachable on foot, how big is the home continent, how many
//! bosses share it — falls out of that labelling.

use crate::geo::{WorldGenerator, WATER_LEVEL, WORLD_SIZE};

/// Grid resolution. 32 m is half a zone: fine enough that a river mouth or a
/// narrow isthmus is resolved, coarse enough that the whole world is ~390 k
/// height samples. At 64 m, separate islands routinely fuse across channels a
/// player would have to swim.
pub const CELL: f32 = 32.0;

/// Cells per side covering the full -10000..10000 world square.
pub const GRID: usize = (2.0 * WORLD_SIZE / CELL) as usize;

/// How wide a water gap still counts as "the same landmass", in cells.
///
/// This is the whole judgement call in this module. Pure land connectivity is
/// the wrong model: Valheim's rivers are 60-100 m wide and run everywhere, so
/// labelling strictly by land splits every continent into a hundred fragments
/// — measured on the default seed, 3 560 components whose largest was 5.2 km².
/// But nobody describing a seed counts a river as a barrier. What they mean by
/// "needs a boat" is open water you cannot simply swim.
///
/// So land is dilated by this radius before labelling, which welds anything
/// separated by up to `2 * SWIM_GAP * CELL` = 128 m of water and leaves real
/// straits alone. Area is still counted from the undilated land, so the
/// reported size of a landmass stays honest.
pub const SWIM_GAP: i32 = 2;

pub struct Landmass {
    /// Component id per cell, or -1 for water / outside the world disc.
    pub label: Vec<i32>,
    /// Cell count per component, indexed by component id.
    pub sizes: Vec<u32>,
    /// The component containing the spawn point, or -1 if spawn is somehow wet.
    pub spawn: i32,
}

#[inline]
fn cell_of(w: f32) -> i32 {
    ((w + WORLD_SIZE) / CELL).floor() as i32
}

#[inline]
fn centre_of(c: usize) -> f32 {
    (c as f32 + 0.5) * CELL - WORLD_SIZE
}

impl Landmass {
    /// Component id at a world position, or -1 if that cell is water.
    pub fn at(&self, wx: f32, wy: f32) -> i32 {
        let (cx, cy) = (cell_of(wx), cell_of(wy));
        if cx < 0 || cy < 0 || cx >= GRID as i32 || cy >= GRID as i32 {
            return -1;
        }
        self.label[cy as usize * GRID + cx as usize]
    }

    /// Whether a position shares the spawn landmass — i.e. is walkable from
    /// the start temple without a boat.
    pub fn on_spawn_landmass(&self, wx: f32, wy: f32) -> bool {
        let l = self.at(wx, wy);
        l >= 0 && l == self.spawn
    }

    /// Area of a component in square kilometres.
    pub fn area_km2(&self, label: i32) -> f32 {
        if label < 0 {
            return 0.0;
        }
        self.sizes[label as usize] as f32 * (CELL * CELL) / 1_000_000.0
    }

    /// A point on land near `(wx, wy)`, searched outward in rings. Locations
    /// sit at their own coordinates but a marker can land a few metres into a
    /// cell the coarse grid calls water; snapping avoids reporting a boss as
    /// unreachable because of rasterisation.
    pub fn nearest_land(&self, wx: f32, wy: f32, max_rings: i32) -> i32 {
        let l = self.at(wx, wy);
        if l >= 0 {
            return l;
        }
        let (cx, cy) = (cell_of(wx), cell_of(wy));
        for r in 1..=max_rings {
            for dy in -r..=r {
                for dx in -r..=r {
                    // Only the ring itself, not its interior.
                    if dx.abs() != r && dy.abs() != r {
                        continue;
                    }
                    let (x, y) = (cx + dx, cy + dy);
                    if x < 0 || y < 0 || x >= GRID as i32 || y >= GRID as i32 {
                        continue;
                    }
                    let l = self.label[y as usize * GRID + x as usize];
                    if l >= 0 {
                        return l;
                    }
                }
            }
        }
        -1
    }
}

/// Build the landmass labelling. ~390 k height samples, which is the whole cost
/// — the flood fill itself is linear and trivial beside it.
pub fn build(wg: &WorldGenerator) -> Landmass {
    let n = GRID;
    let mut land = vec![false; n * n];
    for cy in 0..n {
        let wy = centre_of(cy);
        for cx in 0..n {
            let wx = centre_of(cx);
            // Outside the playable disc is water by definition; skipping it
            // also avoids paying for height in the corners of the square.
            if (wx * wx + wy * wy).sqrt() > WORLD_SIZE {
                continue;
            }
            land[cy * n + cx] = wg.height(wx, wy) > WATER_LEVEL;
        }
    }

    // Dilate land by SWIM_GAP so short swims do not split a continent. A
    // square kernel is enough here and separates into two cheap passes.
    let mut wide = vec![false; n * n];
    {
        let mut row = vec![false; n * n];
        for y in 0..n {
            for x in 0..n {
                let lo = x.saturating_sub(SWIM_GAP as usize);
                let hi = (x + SWIM_GAP as usize).min(n - 1);
                row[y * n + x] = (lo..=hi).any(|i| land[y * n + i]);
            }
        }
        for y in 0..n {
            let lo = y.saturating_sub(SWIM_GAP as usize);
            let hi = (y + SWIM_GAP as usize).min(n - 1);
            for x in 0..n {
                wide[y * n + x] = (lo..=hi).any(|j| row[j * n + x]);
            }
        }
    }

    // 4-connected flood fill over the dilated set. Deliberately not
    // 8-connected: diagonal-only contact is a corner touch, which welds
    // landmasses that meet at a single point.
    let mut label = vec![-1i32; n * n];
    let mut sizes: Vec<u32> = Vec::new();
    let mut stack: Vec<u32> = Vec::new();
    for start in 0..n * n {
        if !wide[start] || label[start] >= 0 {
            continue;
        }
        let id = sizes.len() as i32;
        let mut size = 0u32;
        label[start] = id;
        stack.push(start as u32);
        while let Some(i) = stack.pop() {
            let i = i as usize;
            // Only real land counts toward area; the dilation is scaffolding.
            if land[i] {
                size += 1;
            }
            let (cx, cy) = (i % n, i / n);
            let visit = |x: usize, y: usize, label: &mut Vec<i32>, stack: &mut Vec<u32>| {
                let j = y * n + x;
                if wide[j] && label[j] < 0 {
                    label[j] = id;
                    stack.push(j as u32);
                }
            };
            if cx > 0 {
                visit(cx - 1, cy, &mut label, &mut stack);
            }
            if cx + 1 < n {
                visit(cx + 1, cy, &mut label, &mut stack);
            }
            if cy > 0 {
                visit(cx, cy - 1, &mut label, &mut stack);
            }
            if cy + 1 < n {
                visit(cx, cy + 1, &mut label, &mut stack);
            }
        }
        sizes.push(size);
    }
    // Cells that only exist because of the dilation are not land; clear them so
    // `at()` still answers "is this point on land" truthfully.
    for i in 0..n * n {
        if !land[i] {
            label[i] = -1;
        }
    }

    let mut lm = Landmass { label, sizes, spawn: -1 };
    // Spawn is always at/near the world origin; snap generously because the
    // start temple sits on a small meadow that can be one cell wide.
    lm.spawn = lm.nearest_land(0.0, 0.0, 24);
    lm
}

/// Area of the spawn landmass only, flooded lazily.
///
/// `build` rasterises the whole world — 390 k height samples, ~55 ms — because
/// the map view wants every component. Seed search only ever asks about the
/// one containing spawn, which is typically a few thousand cells, so flooding
/// outward from spawn and evaluating height on demand is one to two orders of
/// magnitude cheaper.
///
/// The swim tolerance is applied by probing: when a neighbour is water, look
/// up to `SWIM_GAP` cells further along the same direction for land. That is
/// the sparse equivalent of dilating the land bitmap, without materialising
/// it.
pub fn home_area_km2(wg: &WorldGenerator) -> f32 {
    use std::collections::{HashMap, HashSet};

    let mut known: HashMap<(i32, i32), bool> = HashMap::new();
    let is_land = |c: (i32, i32), known: &mut HashMap<(i32, i32), bool>| -> bool {
        if let Some(&v) = known.get(&c) {
            return v;
        }
        let wx = centre_of(c.0 as usize);
        let wy = centre_of(c.1 as usize);
        let v = (wx * wx + wy * wy).sqrt() <= WORLD_SIZE && wg.height(wx, wy) > WATER_LEVEL;
        known.insert(c, v);
        v
    };

    // Spawn sits on a small meadow; find its cell by spiralling out.
    let origin = (cell_of(0.0), cell_of(0.0));
    let mut start = None;
    'outer: for r in 0..=24i32 {
        for dy in -r..=r {
            for dx in -r..=r {
                if dx.abs() != r && dy.abs() != r && r > 0 {
                    continue;
                }
                let c = (origin.0 + dx, origin.1 + dy);
                if is_land(c, &mut known) {
                    start = Some(c);
                    break 'outer;
                }
            }
        }
    }
    let Some(start) = start else { return 0.0 };

    let mut seen: HashSet<(i32, i32)> = HashSet::new();
    let mut stack = vec![start];
    seen.insert(start);
    let mut cells = 0u32;
    while let Some(c) = stack.pop() {
        cells += 1;
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            // Step across up to SWIM_GAP cells of water, matching `build`'s
            // dilation: a river is not a reason to call this a different
            // landmass, an ocean strait is.
            for k in 1..=(SWIM_GAP + 1) {
                let n = (c.0 + dx * k, c.1 + dy * k);
                if n.0 < 0 || n.1 < 0 || n.0 >= GRID as i32 || n.1 >= GRID as i32 {
                    break;
                }
                if is_land(n, &mut known) {
                    if seen.insert(n) {
                        stack.push(n);
                    }
                    break;
                }
            }
        }
    }
    cells as f32 * (CELL * CELL) / 1_000_000.0
}
