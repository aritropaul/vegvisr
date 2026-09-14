//! Port of Valheim's `WorldGenerator` terrain + biome classification.
//!
//! Transcribed from the decompiled `WorldGenerator.cs` (cross-checked across
//! six independent mirrors and the MIT-licensed Avledet C++ port). The core
//! math below was byte-stable from game build 0.216.5 through 0.221.12.

use crate::perlin::perlin;
use crate::random::{seed_from_name, UnityRandom};
use crate::fastnoise::FastNoise;
use crate::rivers::Rivers;

pub const WORLD_SIZE: f32 = 10000.0;
pub const WATER_EDGE: f32 = 10500.0;
pub const WATER_TRESHOLD: f32 = 0.05;
pub const HEIGHT_MULTIPLIER: f32 = 200.0;
pub const ASHLANDS_MIN_DISTANCE: f32 = 12000.0;
pub const ASHLANDS_Y_OFFSET: f32 = -4000.0;
pub const DEEP_NORTH_MIN_DISTANCE: f32 = 12000.0;
pub const DEEP_NORTH_Y_OFFSET: f32 = 4000.0;
/// Radii outside which the polar ocean gaps are provably 1.0 — the arc radius
/// (12000 ± 100 from the angle term) widened by the 400 m gap falloff.
const GAP_INNER: f32 = 11400.0;
const GAP_OUTER: f32 = 12600.0;
/// Sea level in world Y units.
pub const WATER_LEVEL: f32 = 30.0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u16)]
pub enum Biome {
    None = 0,
    Meadows = 1,
    Swamp = 2,
    Mountain = 4,
    BlackForest = 8,
    Plains = 16,
    AshLands = 32,
    DeepNorth = 64,
    Ocean = 256,
    Mistlands = 512,
}

/// `DUtils.PerlinNoise(double, double)` — the coordinates are computed wide
/// and narrowed only at the call boundary.
#[inline(always)]
pub fn pn(x: f64, y: f64) -> f64 {
    perlin(x as f32, y as f32) as f64
}

#[inline(always)]
pub fn length(x: f32, y: f32) -> f32 {
    // `DUtils.Length` squares and sums in double before the sqrt. In f32 the
    // sum reaches ~2e8 at world-edge distances, where the representable step
    // is ~16, so the radius comes back wrong by up to ~4e-4 m — enough to sit
    // on the wrong side of the `dist > 2000` / `dist < 6000` biome-radius
    // comparisons for a handful of pixels.
    (((x as f64) * (x as f64) + (y as f64) * (y as f64)).sqrt()) as f32
}

/// `DUtils.Lerp`. Two details that look like noise and are not: it clamps at
/// both ends, and it interpolates as `a*(1-t) + b*t` in double rather than the
/// usual `a + (b-a)*t`. The two forms disagree in the last bits.
#[inline(always)]
pub fn lerp(a: f32, b: f32, t: f32) -> f32 {
    if t <= 0.0 { return a; }
    if t >= 1.0 { return b; }
    ((a as f64) * (1.0 - t as f64) + (b as f64) * (t as f64)) as f32
}

#[inline(always)]
pub fn lerp_f64(a: f64, b: f64, t: f64) -> f64 {
    if t <= 0.0 { return a; }
    if t >= 1.0 { return b; }
    a * (1.0 - t) + b * t
}

/// `DUtils.Fbm` — the **double** overload. The f32 one in `heights.rs` is
/// the separate float overload the forest factor calls; the game has both.
#[inline(always)]
pub fn fbm_f64(px: f32, py: f32, octaves: i32, lacunarity: f64, gain: f64) -> f64 {
    let mut sum = 0.0;
    let mut amp = 1.0;
    let mut x = px as f64;
    let mut y = py as f64;
    for _ in 0..octaves {
        sum += amp * pn(x, y);
        amp *= gain;
        x *= lacunarity;
        y *= lacunarity;
    }
    sum
}

#[inline(always)]
pub fn clamp01(v: f32) -> f32 {
    if v > 1.0 { 1.0 } else if v < 0.0 { 0.0 } else { v }
}

#[inline(always)]
pub fn lerp_step(l: f32, h: f32, v: f32) -> f32 {
    clamp01((v - l) / (h - l))
}

#[inline(always)]
pub fn smooth_step(lo: f32, hi: f32, x: f32) -> f32 {
    let t = clamp01((((x as f64) - lo as f64) / ((hi as f64) - lo as f64)) as f32) as f64;
    (t * t * (3.0 - 2.0 * t)) as f32
}

#[inline(always)]
pub fn clamp01_f64(v: f64) -> f64 {
    if v > 1.0 { 1.0 } else if v < 0.0 { 0.0 } else { v }
}

/// `DUtils.MathfLikeSmoothStep`. The game narrows the result to f32 before
/// widening it back to f64 on return; that rounding is load-bearing for the
/// ocean-gap edge, so it is reproduced rather than tidied away.
#[inline(always)]
pub fn mathf_like_smooth_step(from: f64, to: f64, t: f64) -> f64 {
    let t = clamp01_f64(t);
    let t = -2.0 * t * t * t + 3.0 * t * t;
    ((to * t + from * (1.0 - t)) as f32) as f64
}

#[inline(always)]
pub fn blend_overlay(a: f64, b: f64) -> f64 {
    if a < 0.5 { 2.0 * a * b } else { 1.0 - 2.0 * (1.0 - a) * (1.0 - b) }
}

#[inline(always)]
pub fn remap(value: f64, in_lo: f64, in_hi: f64, out_lo: f64, out_hi: f64) -> f64 {
    let t = if in_lo == in_hi { 0.0 } else { clamp01_f64((value - in_lo) / (in_hi - in_lo)) };
    out_lo + (out_hi - out_lo) * t
}

pub struct WorldGenerator {
    pub seed: i32,
    pub offset0: f32,
    pub offset1: f32,
    pub offset2: f32,
    pub offset3: f32,
    pub offset4: f32,
    pub river_seed: i32,
    pub stream_seed: i32,

    // VersionSetup(): tunables that differ for legacy worlds.
    min_mountain_distance: f32,
    max_marsh_distance: f32,
    min_darkland_noise: f32,

    pub rivers: Rivers,
    /// Cellular/simplex source for Ashlands terrain. The game holds this in a
    /// `static` guarded by a null check, so in-game it keeps the seed of the
    /// first world loaded that session; one instance per generator reproduces
    /// the intended (and overwhelmingly common) single-world case.
    pub noise: FastNoise,
}

impl WorldGenerator {
    pub fn from_seed_name(name: &str, world_gen_version: i32) -> Self {
        Self::from_seed(seed_from_name(name), world_gen_version)
    }

    /// A generator with the offsets drawn but **no river/lake/stream
    /// pregeneration**. Biome classification never reads river data — verified
    /// bit-identical over 125 627 samples — so seed search can screen
    /// candidates on biomes alone for ~1 ms instead of ~145 ms. Heights from
    /// this instance are wrong wherever water carved the terrain; use it only
    /// for `biome`/`base_height`.
    pub fn biome_only(seed: i32, world_gen_version: i32) -> Self {
        Self::build(seed, world_gen_version, false)
    }

    pub fn from_seed(seed: i32, world_gen_version: i32) -> Self {
        Self::build(seed, world_gen_version, true)
    }

    fn build(seed: i32, world_gen_version: i32, pregenerate: bool) -> Self {
        // VersionSetup(version)
        let mut min_mountain_distance = 1000.0f32;
        let mut max_marsh_distance = 6000.0f32;
        let mut min_darkland_noise = 0.4f32;
        if world_gen_version <= 0 {
            min_mountain_distance = 1500.0;
        }
        if world_gen_version <= 1 {
            min_darkland_noise = 0.5;
            max_marsh_distance = 8000.0;
        }

        // Draw order is load-bearing: offset0..3, riverSeed, streamSeed, then
        // offset4 LAST. Getting this wrong silently produces a different world.
        let mut r = UnityRandom::new(seed);
        let offset0 = r.range_i32(-10000, 10000) as f32;
        let offset1 = r.range_i32(-10000, 10000) as f32;
        let offset2 = r.range_i32(-10000, 10000) as f32;
        let offset3 = r.range_i32(-10000, 10000) as f32;
        let river_seed = r.range_i32(i32::MIN, i32::MAX);
        let stream_seed = r.range_i32(i32::MIN, i32::MAX);
        let offset4 = r.range_i32(-10000, 10000) as f32;

        let mut wg = Self {
            seed,
            offset0,
            offset1,
            offset2,
            offset3,
            offset4,
            river_seed,
            stream_seed,
            min_mountain_distance,
            max_marsh_distance,
            min_darkland_noise,
            rivers: Rivers::empty(),
            noise: FastNoise::new(seed),
        };
        if pregenerate {
            wg.pregenerate();
        }
        wg
    }

    #[inline(always)]
    pub fn world_angle(&self, wx: f32, wy: f32) -> f32 {
        // NOTE: atan2(x, y), not the conventional atan2(y, x).
        (wx.atan2(wy) * 20.0).sin()
    }

    /// `GetBaseHeight`. This is the one generator function that keeps its
    /// coordinate accumulation in **double** all the way to the noise call —
    /// `double num5 = wx; num5 += 100000.0 + (double)m_offset0;` with no
    /// intermediate narrowing. Every per-biome height function does the
    /// opposite (`wx = (float)((double)wx + 100000.0 + m_offset3)`), so only
    /// this one needs the wider type.
    ///
    /// Running it in f32 throughout is visually indistinguishable — measured
    /// max divergence 5.0e-5, i.e. 1 cm of terrain — but it flips roughly one
    /// pixel in 400 000 across the ocean/mountain thresholds, and those flips
    /// land on coastlines where they are most visible.
    pub fn base_height(&self, wx_in: f32, wy_in: f32) -> f32 {
        let dist = length(wx_in, wy_in);
        let x = wx_in as f64 + 100000.0 + self.offset0 as f64;
        let y = wy_in as f64 + 100000.0 + self.offset1 as f64;

        // The literals are the f32 constants the game uses, written out at the
        // width the double-precision path actually sees them.
        const A: f64 = 0.0020000000949949026;
        const B: f64 = 0.003000000026077032;
        const C: f64 = 0.004999999888241291;
        const D: f64 = 0.009999999776482582;

        let mut h = 0.0f32;
        h = (h as f64 + pn(x * A * 0.5, y * A * 0.5) * pn(x * B * 0.5, y * B * 0.5)) as f32;
        h = (h as f64 + pn(x * A, y * A) * pn(x * B, y * B) * h as f64 * 0.8999999761581421) as f32;
        h = (h as f64 + pn(x * C, y * C) * pn(x * D, y * D) * 0.5 * h as f64) as f32;
        h = (h as f64 - 0.07000000029802322) as f32;

        // Flattening mask: carves broad lowland plateaus away from the centre.
        let n4 = pn(x * A * 0.25 + 0.12300000339746475, y * A * 0.25 + 0.15123000741004944);
        let n5 = pn(x * A * 0.25 + 0.32100000977516174, y * A * 0.25 + 0.23100000619888306);
        let v = ((n4 - n5) as f32).abs();
        let mut mask = 1.0 - lerp_step(0.02, 0.12, v) as f64;
        mask *= smooth_step(744.0, 1000.0, dist) as f64;
        h = ((h as f64) * (1.0 - mask)) as f32;

        // World edge falloff.
        if dist > WORLD_SIZE {
            let t = lerp_step(WORLD_SIZE, WATER_EDGE, dist);
            h = lerp(h, -0.2, t);
            const EDGE: f32 = 10490.0;
            if dist > EDGE {
                let t2 = lerp_step(EDGE, WATER_EDGE, dist);
                h = lerp(h, -2.0, t2);
            }
            return h;
        }

        // Keep big mountains away from spawn.
        if dist < self.min_mountain_distance && h > 0.28 {
            let t3 = clamp01((((h as f64) - 0.2800000011920929) / 0.09999999403953552) as f32);
            h = lerp(
                lerp(0.28, 0.38, t3),
                h,
                lerp_step(self.min_mountain_distance - 400.0, self.min_mountain_distance, dist),
            );
        }
        h
    }

    /// How far past the Ashlands boundary a point is, in units of 300 m.
    /// Note the angle term is sampled at `wy + ashlandsYOffset` here but at
    /// plain `wy` in `is_ashlands` — that asymmetry is in the game.
    #[inline]
    pub fn ashlands_ocean_gradient(&self, wx: f32, wy: f32) -> f32 {
        let a = self.world_angle(wx, wy + ASHLANDS_Y_OFFSET) as f64 * 100.0;
        ((length(wx, wy + ASHLANDS_Y_OFFSET) as f64 - (ASHLANDS_MIN_DISTANCE as f64 + a)) / 300.0)
            as f32
    }

    /// `CreateAshlandsGap` — a multiplier on the height scale, not on the
    /// height itself. It reaches 0 exactly on the Ashlands biome boundary and
    /// returns to 1 over 400 m either side, which is what drowns the border
    /// into the ocean strip that makes Ashlands an island.
    #[inline]
    pub fn create_ashlands_gap(&self, wx: f32, wy: f32) -> f64 {
        // The angle term is bounded by ±100, so the arc always lies within
        // [11900, 12100] and the gap is only below 1 within 400 m of it.
        // Anything outside [11400, 12600] is unambiguously untouched, which
        // lets the common case skip an atan2 and a sin — worth doing, because
        // this runs on every height sample in the world.
        let r = length(wx, wy + ASHLANDS_Y_OFFSET);
        if !(GAP_INNER..=GAP_OUTER).contains(&r) {
            return 1.0;
        }
        let a = self.world_angle(wx, wy) as f64 * 100.0;
        let v = r as f64 - (ASHLANDS_MIN_DISTANCE as f64 + a);
        let v = clamp01_f64(v.abs() / 400.0) as f32;
        mathf_like_smooth_step(0.0, 1.0, v as f64)
    }

    /// `CreateDeepNorthGap` — the same mechanism at the north pole.
    #[inline]
    pub fn create_deep_north_gap(&self, wx: f32, wy: f32) -> f64 {
        let r = length(wx, wy + DEEP_NORTH_Y_OFFSET);
        if !(GAP_INNER..=GAP_OUTER).contains(&r) {
            return 1.0;
        }
        let a = self.world_angle(wx, wy) as f64 * 100.0;
        let v = r as f64 - (DEEP_NORTH_MIN_DISTANCE as f64 + a);
        let v = clamp01_f64(v.abs() / 400.0) as f32;
        mathf_like_smooth_step(0.0, 1.0, v as f64)
    }

    #[inline]
    pub fn is_ashlands(&self, wx: f32, wy: f32) -> bool {
        let a = self.world_angle(wx, wy) * 100.0;
        length(wx, wy + -4000.0) > 12000.0 + a
    }

    #[inline]
    pub fn is_deep_north(&self, wx: f32, wy: f32) -> bool {
        let a = self.world_angle(wx, wy) * 100.0;
        length(wx, wy + 4000.0) > 12000.0 + a
    }

    #[inline]
    pub fn biome(&self, wx: f32, wy: f32) -> Biome {
        self.biome_with_base(wx, wy).0
    }

    /// Returns the biome alongside the base height it was derived from, so
    /// callers that also need terrain height don't pay for it twice.
    pub fn biome_with_base(&self, wx: f32, wy: f32) -> (Biome, f32) {
        let dist = length(wx, wy);
        let base = self.base_height(wx, wy);
        let a = self.world_angle(wx, wy) * 100.0;

        if length(wx, wy + -4000.0) > 12000.0 + a {
            return (Biome::AshLands, base);
        }
        if base <= 0.02 {
            return (Biome::Ocean, base);
        }
        if length(wx, wy + 4000.0) > 12000.0 + a {
            return if base > 0.4 { (Biome::Mountain, base) } else { (Biome::DeepNorth, base) };
        }
        if base > 0.4 {
            return (Biome::Mountain, base);
        }
        if perlin((self.offset0 + wx) * 0.001, (self.offset0 + wy) * 0.001) > 0.6
            && dist > 2000.0
            && dist < self.max_marsh_distance
            && base > 0.05
            && base < 0.25
        {
            return (Biome::Swamp, base);
        }
        if perlin((self.offset4 + wx) * 0.001, (self.offset4 + wy) * 0.001) > self.min_darkland_noise
            && dist > 6000.0 + a
            && dist < 10000.0
        {
            return (Biome::Mistlands, base);
        }
        if perlin((self.offset1 + wx) * 0.001, (self.offset1 + wy) * 0.001) > 0.4
            && dist > 3000.0 + a
            && dist < 8000.0
        {
            return (Biome::Plains, base);
        }
        if perlin((self.offset2 + wx) * 0.001, (self.offset2 + wy) * 0.001) > 0.4
            && dist > 600.0 + a
            && dist < 6000.0
        {
            return (Biome::BlackForest, base);
        }
        if dist > 5000.0 + a {
            return (Biome::BlackForest, base);
        }
        (Biome::Meadows, base)
    }
}
