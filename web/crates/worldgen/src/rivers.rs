//! Lakes, rivers and streams — Valheim's `Pregenerate()` pass.
//!
//! Runs once per seed. Order is load-bearing: FindLakes -> PlaceRivers
//! (rendered into the point grid) -> PlaceStreams, because stream placement
//! samples terrain heights that already include the rivers carved above.

use crate::geo::{length, lerp, lerp_step, WorldGenerator};
use crate::random::UnityRandom;
use std::collections::HashMap;

pub const RIVER_GRID_SIZE: f32 = 64.0;

#[derive(Clone, Copy)]
pub struct RiverPoint {
    pub x: f32,
    pub y: f32,
    /// Radius.
    pub w: f32,
    /// Radius squared, cached.
    pub w2: f32,
}

#[derive(Clone, Copy)]
pub struct River {
    pub p0: (f32, f32),
    pub p1: (f32, f32),
    pub width_min: f32,
    pub width_max: f32,
    pub curve_width: f32,
    pub curve_wavelength: f32,
}

#[derive(Default)]
pub struct Rivers {
    grid: HashMap<(i32, i32), Vec<RiverPoint>>,
}

#[inline(always)]
pub fn river_grid(wx: f32, wy: f32) -> (i32, i32) {
    (
        ((wx + 32.0) / 64.0).floor() as i32,
        ((wy + 32.0) / 64.0).floor() as i32,
    )
}

impl Rivers {
    pub fn empty() -> Self {
        Self { grid: HashMap::new() }
    }

    pub fn is_empty(&self) -> bool {
        self.grid.is_empty()
    }

    /// Linear cone falloff; `weight` is the strongest single point, `width` is
    /// the falloff-weighted mean radius. Deliberately NOT a smoothstep.
    #[inline]
    pub fn weight_at(&self, wx: f32, wy: f32) -> (f32, f32) {
        let cell = river_grid(wx, wy);
        let Some(points) = self.grid.get(&cell) else {
            return (0.0, 0.0);
        };
        let mut weight = 0.0f32;
        let mut acc_w = 0.0f32;
        let mut acc_t = 0.0f32;
        for rp in points {
            let dx = rp.x - wx;
            let dy = rp.y - wy;
            let d2 = dx * dx + dy * dy;
            if d2 < rp.w2 {
                let t = 1.0 - d2.sqrt() / rp.w;
                if t > weight {
                    weight = t;
                }
                acc_w += rp.w * t;
                acc_t += t;
            }
        }
        let width = if acc_t > 0.0 { acc_w / acc_t } else { 0.0 };
        (weight, width)
    }

    pub fn debug_cell_count(&self) -> usize { self.grid.len() }
    pub fn debug_point_count(&self) -> usize { self.grid.values().map(|v| v.len()).sum() }
    /// Order-independent so hash-map layout cannot affect the result.
    pub fn debug_checksum(&self) -> u64 {
        let mut acc: u64 = 0;
        for pts in self.grid.values() {
            for p in pts {
                acc = acc
                    .wrapping_add((p.x.to_bits() as u64).wrapping_mul(0x9E3779B1))
                    .wrapping_add((p.y.to_bits() as u64).wrapping_mul(0x85EBCA77))
                    .wrapping_add(p.w.to_bits() as u64);
            }
        }
        acc
    }

    fn add_point(&mut self, x: f32, y: f32, r: f32) {
        let home = river_grid(x, y);
        let span = (r / 64.0).ceil() as i32;
        for i in (home.1 - span)..=(home.1 + span) {
            for j in (home.0 - span)..=(home.0 + span) {
                // InsideRiverGrid: inflate the footprint by half a cell.
                let cx = j as f32 * 64.0;
                let cy = i as f32 * 64.0;
                if (x - cx).abs() < r + 32.0 && (y - cy).abs() < r + 32.0 {
                    self.grid.entry((j, i)).or_default().push(RiverPoint {
                        x,
                        y,
                        w: r,
                        w2: r * r,
                    });
                }
            }
        }
    }

    /// Rasterise river centrelines into the 64m point grid. Each sample gets
    /// its own randomised radius, which is what gives the banks their wobble.
    pub fn render(&mut self, rivers: &[River], rng: &mut UnityRandom) {
        for river in rivers {
            let step = river.width_min / 8.0;
            let dx = river.p1.0 - river.p0.0;
            let dy = river.p1.1 - river.p0.1;
            let dist = length(dx, dy);
            if dist <= 0.0 || step <= 0.0 {
                continue;
            }
            let nx = dx / dist;
            let ny = dy / dist;
            // Perpendicular.
            let px = -ny;
            let py = nx;

            let mut t = 0.0f32;
            while t <= dist {
                let a = t / river.curve_wavelength;
                // Triple-sine meander.
                let off = a.sin()
                    * (a * 0.634_119_99).sin()
                    * (a * 0.334_120_01).sin()
                    * river.curve_width;
                let r = rng.range_f32(river.width_min, river.width_max);
                let x = river.p0.0 + nx * t + px * off;
                let y = river.p0.1 + ny * t + py * off;
                self.add_point(x, y, r);
                t += step;
            }
        }
    }
}

impl WorldGenerator {
    /// Height carving applied by every per-biome height function.
    #[inline]
    pub fn add_rivers(&self, wx: f32, wy: f32, h: f32) -> f32 {
        if self.rivers.is_empty() {
            return h;
        }
        let (weight, width) = self.rivers.weight_at(wx, wy);
        if weight <= 0.0 {
            return h;
        }
        let t = lerp_step(20.0, 60.0, width);
        let bed = lerp(0.14, 0.12, t);
        let bank = lerp(0.139, 0.128, t);
        let mut h = h;
        if h > bed {
            h = lerp(h, bed, weight);
        }
        if h > bank {
            let t2 = lerp_step(0.85, 1.0, weight);
            h = lerp(h, bank, t2);
        }
        h
    }

    pub fn debug_find_lakes(&self) -> Vec<(f32, f32)> { self.find_lakes() }

    /// 128m grid scan for sub-waterline terrain, then greedy cluster merge.
    fn find_lakes(&self) -> Vec<(f32, f32)> {
        let mut pts: Vec<(f32, f32)> = Vec::new();
        let mut y = -10000.0f32;
        while y <= 10000.0 {
            let mut x = -10000.0f32;
            while x <= 10000.0 {
                if !(length(x, y) > 10000.0) && self.base_height(x, y) < 0.05 {
                    pts.push((x, y));
                }
                x += 128.0;
            }
            y += 128.0;
        }
        merge_points(pts, 800.0)
    }

    fn have_river(rivers: &[River], a: (f32, f32), b: (f32, f32)) -> bool {
        rivers
            .iter()
            .any(|r| (r.p0 == a && r.p1 == b) || (r.p0 == b && r.p1 == a))
    }

    fn have_river_at(rivers: &[River], p: (f32, f32)) -> bool {
        rivers.iter().any(|r| r.p0 == p || r.p1 == p)
    }

    /// A river may not cross terrain above `height_limit`, and must dip to
    /// water level somewhere along its length.
    fn is_river_allowed(&self, p0: (f32, f32), p1: (f32, f32), step: f32, height_limit: f32) -> bool {
        let dist = length(p1.0 - p0.0, p1.1 - p0.1);
        if dist <= 0.0 {
            return false;
        }
        let nx = (p1.0 - p0.0) / dist;
        let ny = (p1.1 - p0.1) / dist;
        let mut all_above_water = true;
        let mut t = step;
        while t <= dist - step {
            let h = self.base_height(p0.0 + nx * t, p0.1 + ny * t);
            if h > height_limit {
                return false;
            }
            if h > 0.05 {
                all_above_water = false;
            }
            t += step;
        }
        !all_above_water
    }

    fn find_random_river_end(
        &self,
        rivers: &[River],
        lakes: &[(f32, f32)],
        p: (f32, f32),
        max_distance: f32,
        height_limit: f32,
        check_step: f32,
        rng: &mut UnityRandom,
    ) -> i32 {
        let mut candidates: Vec<i32> = Vec::new();
        for (i, &q) in lakes.iter().enumerate() {
            if q != p
                && length(p.0 - q.0, p.1 - q.1) < max_distance
                && !Self::have_river(rivers, p, q)
                && self.is_river_allowed(p, q, check_step, height_limit)
            {
                candidates.push(i as i32);
            }
        }
        if candidates.is_empty() {
            return -1;
        }
        candidates[rng.range_i32(0, candidates.len() as i32) as usize]
    }

    fn place_rivers(&self, lakes: &[(f32, f32)], rng: &mut UnityRandom) -> Vec<River> {
        let mut rivers: Vec<River> = Vec::new();
        let mut pending: Vec<(f32, f32)> = lakes.to_vec();
        while pending.len() > 1 {
            let p = pending[0];
            let mut idx = self.find_random_river_end(&rivers, lakes, p, 2000.0, 0.4, 128.0, rng);
            if idx == -1 && !Self::have_river_at(&rivers, p) {
                idx = self.find_random_river_end(&rivers, lakes, p, 5000.0, 0.4, 128.0, rng);
            }
            if idx != -1 {
                let q = lakes[idx as usize];
                let width_max = rng.range_f32(60.0, 100.0);
                let width_min = rng.range_f32(60.0, width_max);
                let d = length(q.0 - p.0, q.1 - p.1);
                rivers.push(River {
                    p0: p,
                    p1: q,
                    width_min,
                    width_max,
                    curve_width: d / 15.0,
                    curve_wavelength: d / 20.0,
                });
            } else {
                pending.remove(0);
            }
        }
        rivers
    }

    fn find_stream_start(&self, rng: &mut UnityRandom) -> Option<(f32, f32)> {
        for _ in 0..100 {
            let x = rng.range_f32(-10000.0, 10000.0);
            let y = rng.range_f32(-10000.0, 10000.0);
            let h = self.pregeneration_height(x, y);
            if h > 26.0 && h < 31.0 {
                return Some((x, y));
            }
        }
        None
    }

    fn find_stream_end(&self, start: (f32, f32), rng: &mut UnityRandom) -> Option<(f32, f32)> {
        let iterations = 100;
        let step = (200.0f32 - 80.0) / iterations as f32;
        let mut len = 200.0f32;
        for _ in 0..iterations {
            len -= step;
            let f = rng.range_f32(0.0, std::f32::consts::PI * 2.0);
            let x = start.0 + f.sin() * len;
            let y = start.1 + f.cos() * len;
            let h = self.pregeneration_height(x, y);
            if h > 36.0 && h < 44.0 {
                return Some((x, y));
            }
        }
        None
    }

    fn place_streams(&self, rng: &mut UnityRandom) -> Vec<River> {
        let mut out = Vec::new();
        for _ in 0..3000 {
            let Some(p) = self.find_stream_start(rng) else { continue };
            let Some(q) = self.find_stream_end(p, rng) else { continue };
            let cx = (p.0 + q.0) * 0.5;
            let cy = (p.1 + q.1) * 0.5;
            let ch = self.pregeneration_height(cx, cy);
            if ch < 26.0 || ch > 44.0 {
                continue;
            }
            let d = length(q.0 - p.0, q.1 - p.1);
            out.push(River {
                p0: p,
                p1: q,
                width_min: 20.0,
                width_max: 20.0,
                curve_width: d / 15.0,
                curve_wavelength: d / 20.0,
            });
        }
        out
    }

    pub(crate) fn pregenerate(&mut self) {
        let lakes = self.find_lakes();

        let mut river_rng = UnityRandom::new(self.river_seed);
        let rivers = self.place_rivers(&lakes, &mut river_rng);
        self.rivers.render(&rivers, &mut river_rng);

        // Streams sample terrain that already includes the rivers above.
        let mut stream_rng = UnityRandom::new(self.stream_seed);
        let streams = self.place_streams(&mut stream_rng);
        self.rivers.render(&streams, &mut stream_rng);
    }
}

/// Greedy cluster merge: repeatedly absorb the nearest remaining point within
/// `range`, averaging positions, until none is left in reach.
fn merge_points(mut points: Vec<(f32, f32)>, range: f32) -> Vec<(f32, f32)> {
    let mut out = Vec::new();
    while !points.is_empty() {
        let mut p = points.remove(0);
        loop {
            let mut best = -1i32;
            let mut best_d = 99999.0f32;
            for (i, &q) in points.iter().enumerate() {
                if q != p {
                    let d = length(p.0 - q.0, p.1 - q.1);
                    if d < range && d < best_d {
                        best = i as i32;
                        best_d = d;
                    }
                }
            }
            if best == -1 {
                break;
            }
            let b = best as usize;
            p = ((p.0 + points[b].0) * 0.5, (p.1 + points[b].1) * 0.5);
            let last = points.len() - 1;
            points[b] = points[last];
            points.pop();
        }
        out.push(p);
    }
    out
}
