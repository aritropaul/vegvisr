//! Per-biome height functions.
//!
//! Every one of these ends by calling `add_rivers`, which is why the river
//! pregeneration pass has to complete before terrain heights are meaningful.

use crate::geo::{
    blend_overlay, clamp01, clamp01_f64, fbm_f64, length, lerp, lerp_f64, lerp_step,
    mathf_like_smooth_step, pn, remap, Biome, WorldGenerator, ASHLANDS_MIN_DISTANCE,
    ASHLANDS_Y_OFFSET, HEIGHT_MULTIPLIER,
};
use crate::perlin::perlin;

impl WorldGenerator {
    /// Shared two-octave detail term used by most biomes.
    #[inline(always)]
    fn detail(&self, wx: f32, wy: f32) -> f32 {
        let mut n = perlin(wx * 0.01, wy * 0.01) * perlin(wx * 0.02, wy * 0.02);
        n += perlin(wx * 0.05, wy * 0.05) * perlin(wx * 0.1, wy * 0.1) * n * 0.5;
        n
    }

    /// Fine surface roughness appended by nearly every biome.
    #[inline(always)]
    fn roughness(&self, wx: f32, wy: f32, h: f32) -> f32 {
        h + perlin(wx * 0.1, wy * 0.1) * 0.01 + perlin(wx * 0.4, wy * 0.4) * 0.003
    }

    fn meadows_height(&self, wx0: f32, wy0: f32, base: f32) -> f32 {
        let wx = wx0 + 100000.0 + self.offset3;
        let wy = wy0 + 100000.0 + self.offset3;
        let n = self.detail(wx, wy);
        let mut h = base + n * 0.1;
        // Flatten meadows as they run up against mountain slopes.
        let over = h - 0.15;
        let t = clamp01(base / 0.4);
        if over > 0.0 {
            h -= over * (1.0 - t) * 0.75;
        }
        h = self.add_rivers(wx0, wy0, h);
        self.roughness(wx, wy, h)
    }

    fn forest_height(&self, wx0: f32, wy0: f32, base: f32) -> f32 {
        let mut h = base;
        let wx = wx0 + 100000.0 + self.offset3;
        let wy = wy0 + 100000.0 + self.offset3;
        h += self.detail(wx, wy) * 0.1;
        h = self.add_rivers(wx0, wy0, h);
        self.roughness(wx, wy, h)
    }

    /// Plains shares Meadows' shape exactly.
    fn plains_height(&self, wx0: f32, wy0: f32, base: f32) -> f32 {
        self.meadows_height(wx0, wy0, base)
    }

    /// Swamp is internally "Marsh": a near-flat sheet just above water level.
    /// Note it does NOT apply offset3.
    fn marsh_height(&self, wx0: f32, wy0: f32) -> f32 {
        let wx = wx0 + 100000.0;
        let wy = wy0 + 100000.0;
        let mut h = 0.137;
        h += perlin(wx * 0.04, wy * 0.04) * perlin(wx * 0.08, wy * 0.08) * 0.03;
        h = self.add_rivers(wx0, wy0, h);
        self.roughness(wx, wy, h)
    }

    /// Central-difference slope of the base height field, used to make peaks
    /// jagged only where the underlying terrain is already steep.
    fn base_height_tilt(&self, wx: f32, wy: f32) -> f32 {
        let a = self.base_height(wx - 1.0, wy);
        let b = self.base_height(wx + 1.0, wy);
        let c = self.base_height(wx, wy - 1.0);
        let d = self.base_height(wx, wy + 1.0);
        (b - a).abs() + (c - d).abs()
    }

    fn snow_mountain_height(&self, wx0: f32, wy0: f32, base: f32) -> f32 {
        let mut h = base;
        let tilt = self.base_height_tilt(wx0, wy0);
        let wx = wx0 + 100000.0 + self.offset3;
        let wy = wy0 + 100000.0 + self.offset3;
        // Double the height above the mountain threshold.
        h += h - 0.4;
        h += self.detail(wx, wy) * 0.2;
        h = self.add_rivers(wx0, wy0, h);
        h = self.roughness(wx, wy, h);
        h + perlin(wx * 0.2, wy * 0.2) * 2.0 * tilt
    }

    fn ocean_height(&self, _wx: f32, _wy: f32, base: f32) -> f32 {
        base
    }

    fn deep_north_height(&self, wx0: f32, wy0: f32, base: f32) -> f32 {
        let mut h = base;
        let wx = wx0 + 100000.0 + self.offset3;
        let wy = wy0 + 100000.0 + self.offset3;
        h += (h - 0.4).max(0.0);
        h += self.detail(wx, wy) * 0.2;
        h *= 1.2;
        h = self.add_rivers(wx0, wy0, h);
        // Deep North is the one biome whose final roughness multiplies the
        // *float* coordinate (`PerlinNoise(wx * 0.1f, wy * 0.1f)`) rather than
        // the widened one every other biome uses. Keeping the shared helper
        // here would silently diverge.
        h += perlin(wx * 0.1, wy * 0.1) * 0.01;
        h + perlin(wx * 0.4, wy * 0.4) * 0.003
    }

    fn mistlands_height(&self, wx0: f32, wy0: f32, base: f32) -> f32 {
        let mut h = base;
        let wx = wx0 + 100000.0 + self.offset3;
        let wy = wy0 + 100000.0 + self.offset3;
        let mut n = perlin(wx * 0.02 * 0.7, wy * 0.02 * 0.7) * perlin(wx * 0.04 * 0.7, wy * 0.04 * 0.7);
        n += perlin(wx * 0.03 * 0.7, wy * 0.03 * 0.7)
            * perlin(wx * 0.05 * 0.7, wy * 0.05 * 0.7)
            * n
            * 0.5;
        if n > 0.0 {
            n = n.powf(1.5);
        }
        h += n * 0.4;
        h = self.add_rivers(wx0, wy0, h);
        let t = clamp01(n * 7.0);
        h += perlin(wx * 0.1, wy * 0.1) * 0.03 * t;
        h += perlin(wx * 0.4, wy * 0.4) * 0.01 * t;
        let smooth = h + perlin(wx * 0.4, wy * 0.4) * 0.002;
        // Quantise into the characteristic Mistlands terraces.
        let stepped = (h * 400.0).ceil() / 400.0;
        lerp(smooth, stepped, t)
    }

    /// `GetAshlandsHeightPregenerate` — the cheap pre-Ashlands-style shape,
    /// still used verbatim by the game during river/stream placement because
    /// the real Ashlands function is far too expensive to call per sample.
    fn ashlands_height_pregenerate(&self, wx0: f32, wy0: f32, base: f32) -> f32 {
        let mut h = base;
        let wx = wx0 + 100000.0 + self.offset3;
        let wy = wy0 + 100000.0 + self.offset3;
        h += self.detail(wx, wy) * 0.1;
        h += 0.1;
        h = self.roughness(wx, wy, h);
        self.add_rivers(wx0, wy0, h)
    }


    /// `GetAshlandsHeight` — the real one, rebuilt from the 0.218.15 decompile.
    ///
    /// This is what turns the southern band into a crescent island with lava
    /// flats: a distance field from the biome arc, blended through cellular
    /// noise, then eroded by a second cellular field and a simplex fractal.
    /// The returned mask alpha is the lava coverage, which the game uses for
    /// texturing; it is surfaced here because it is the only signal that
    /// distinguishes molten ground from ash.
    ///
    /// `cheap` drops the two noise loops from 5 and 3 octaves to 2, which is
    /// what the game uses for distant LOD.
    fn ashlands_height(&self, wx0: f32, wy0: f32, base: f32, cheap: bool) -> (f32, f32) {
        let x0 = wx0 as f64;
        let y0 = wy0 as f64;
        let a = base as f64;

        // Distance from the Ashlands arc, softened over 1 km either side. Note
        // the arc used here is pulled 30% back toward the world centre
        // relative to the one `is_ashlands` classifies against.
        let ang = self.world_angle(wx0, wy0) as f64 * 100.0;
        let yo = ASHLANDS_Y_OFFSET as f64;
        let d = ((x0 * x0 + (y0 + yo - yo * 0.3) * (y0 + yo - yo * 0.3)).sqrt())
            - (ASHLANDS_MIN_DISTANCE as f64 + ang);
        let mut shore = 1.0 - clamp01_f64(d.abs() / 1000.0);
        shore = mathf_like_smooth_step(0.1, 1.0, shore);
        // Taper toward the east and west tips of the crescent.
        shore *= 1.0 - clamp01_f64(x0.abs() / 7500.0);

        // Fade to open ocean approaching the world edge.
        let edge = 1.0 - clamp01_f64((length(wx0, wy0) as f64 - 10150.0) / 600.0);

        let x = x0 + (100000.0f32 + self.offset3) as f64;
        let y = y0 + (100000.0f32 + self.offset3) as f64;

        // Broad cellular relief, smooth-stepped per octave before summing.
        let mut c = 0.0f64;
        let mut amp = 1.0f64;
        let mut freq = 0.33000001311302185f64;
        for _ in 0..(if cheap { 2 } else { 5 }) {
            c += amp * mathf_like_smooth_step(0.0, 1.0, self.noise.cellular(x * freq, y * freq));
            freq *= 2.0;
            amp *= 0.5;
        }
        c = remap(c, -1.0, 1.0, 0.0, 1.0);
        let relief = lerp_f64(shore, blend_overlay(shore, c), 0.5);

        let mut h = lerp_f64(a, 0.15000000596046448, 0.75);
        h += relief * 0.5;
        h = lerp_f64(-1.0, h, mathf_like_smooth_step(0.0, 1.0, edge));

        // Second, much finer cellular field, raised to the 4th power so only
        // the sharpest cell walls survive — this is the lava-channel mask.
        let lava_floor = 0.15f64;
        let mut cell = 0.0f64;
        let mut amp2 = 1.0f64;
        let mut freq2 = 8.0f64;
        for _ in 0..(if cheap { 2 } else { 3 }) {
            cell += amp2 * self.noise.cellular(x * freq2, y * freq2);
            freq2 *= 2.0;
            amp2 *= 0.5;
        }
        cell = remap(cell, -1.0, 1.0, 0.0, 1.0);
        cell = clamp01_f64(cell.powf(4.0) * 2.0);

        let mut sx = self.noise.simplex_fractal(x * 0.075, y * 0.075);
        sx = remap(sx, -1.0, 1.0, 0.0, 1.0);
        sx = sx.powf(1.399999976158142);
        h *= sx;

        let mut f = fbm_f64(
            (x * 0.009999999776482582) as f32,
            (y * 0.009999999776482582) as f32,
            3,
            2.0,
            0.5,
        );
        f *= clamp01_f64(remap(shore, 0.0, 0.5, 0.5, 1.0));
        f = clamp01_f64((f - 0.699999988079071) / (1.0 - 0.699999988079071));
        f = f.powf(2.0);

        let mut lava = blend_overlay(f, cell);
        lava *= clamp01_f64((h - lava_floor - 0.02) / 0.01);

        // Carve the channels down by a noisy depth, floored just above the
        // lava surface so the molten sheet stays flat.
        let mut depth = pn(x * 0.05 + 5124.0, y * 0.05 + 5000.0);
        depth = depth.powf(2.0);
        depth = remap(depth, 0.0, 1.0, 0.009999999776482582, 0.054999999701976776);
        let carved = ((h - depth) as f32)
            .clamp((lava_floor + 0.009999999776482582) as f32, 5000.0) as f64;
        h = lerp_f64(h, carved, lava);

        (h as f32, lava as f32)
    }

    pub fn biome_height(&self, biome: Biome, wx: f32, wy: f32) -> f32 {
        self.biome_height_with_base(biome, wx, wy, self.base_height(wx, wy))
    }

    /// Same as `biome_height` but reuses an already-computed base height.
    /// `base_height` is ~8 Perlin calls, so avoiding the recompute roughly
    /// halves the cost of a combined biome+height sample.
    pub fn biome_height_with_base(&self, biome: Biome, wx: f32, wy: f32, base: f32) -> f32 {
        if length(wx, wy) > 10500.0 {
            return -2.0 * HEIGHT_MULTIPLIER;
        }
        // `GetBiomeHeight` scales by the height multiplier *times both ocean
        // gaps*. The gaps are 0 on the Ashlands and Deep North biome borders,
        // so whatever the per-biome function returns there is flattened to sea
        // level — this is what cuts both polar biomes off as islands. Note it
        // multiplies the scale, not the height, so it also drowns terrain on
        // the mainland side of the border, not just inside the biome.
        let mult = (HEIGHT_MULTIPLIER as f64
            * self.create_ashlands_gap(wx, wy)
            * self.create_deep_north_gap(wx, wy)) as f32;
        self.biome_height_raw(biome, wx, wy, base) * mult
    }

    fn biome_height_raw(&self, biome: Biome, wx: f32, wy: f32, base: f32) -> f32 {
        match biome {
            Biome::Meadows => self.meadows_height(wx, wy, base),
            Biome::Swamp => self.marsh_height(wx, wy),
            Biome::Mountain => self.snow_mountain_height(wx, wy, base),
            Biome::BlackForest => self.forest_height(wx, wy, base),
            Biome::Plains => self.plains_height(wx, wy, base),
            Biome::DeepNorth => self.deep_north_height(wx, wy, base),
            Biome::AshLands => self.ashlands_height(wx, wy, base, false).0,
            Biome::Ocean => self.ocean_height(wx, wy, base),
            Biome::Mistlands => self.mistlands_height(wx, wy, base),
            Biome::None => 0.0,
        }
    }

    /// `GetPregenerationHeight` — used during stream placement, before the
    /// Ashlands/DeepNorth ocean gap is applied. Mistlands falls back to plain
    /// forest height at this stage.
    pub fn pregeneration_height(&self, wx: f32, wy: f32) -> f32 {
        if length(wx, wy) > 10500.0 {
            return -2.0 * HEIGHT_MULTIPLIER;
        }
        let (b, base) = self.biome_with_base(wx, wy);
        match b {
            Biome::Mistlands => self.forest_height(wx, wy, base) * HEIGHT_MULTIPLIER,
            Biome::AshLands => self.ashlands_height_pregenerate(wx, wy, base) * HEIGHT_MULTIPLIER,
            other => self.biome_height_raw(other, wx, wy, base) * HEIGHT_MULTIPLIER,
        }
    }

    /// Final world-space terrain height at a point.
    #[inline]
    pub fn height(&self, wx: f32, wy: f32) -> f32 {
        let (b, base) = self.biome_with_base(wx, wy);
        self.biome_height_with_base(b, wx, wy, base)
    }

    /// Combined sample. Computes the shared base height exactly once.
    #[inline]
    pub fn sample(&self, wx: f32, wy: f32) -> (Biome, f32) {
        let (b, base) = self.biome_with_base(wx, wy);
        (b, self.biome_height_with_base(b, wx, wy, base))
    }

    /// Forest density field; `< 1.15` is "in forest". Drives tree cover and
    /// several POI placement filters.
    pub fn forest_factor(&self, wx: f32, wy: f32) -> f32 {
        fbm(wx * 0.01 * 0.4, wy * 0.01 * 0.4, 3, 1.6, 0.7)
    }

    /// Terrain roughness over a radius, sampled exactly the way the game does
    /// it: 10 `Random.insideUnitCircle` probes drawn from the caller's stream.
    pub fn terrain_delta(
        &self,
        cx: f32,
        cy: f32,
        radius: f32,
        rng: &mut crate::random::UnityRandom,
    ) -> f32 {
        let mut hi = -999999.0f32;
        let mut lo = 999999.0f32;
        for _ in 0..10 {
            let (ox, oy) = rng.inside_unit_circle();
            let h = self.height(cx + ox * radius, cy + oy * radius);
            if h < lo {
                lo = h;
            }
            if h > hi {
                hi = h;
            }
        }
        hi - lo
    }
}

fn fbm(x: f32, y: f32, octaves: i32, lacunarity: f32, gain: f32) -> f32 {
    let mut sum = 0.0;
    let mut amp = 1.0;
    let (mut px, mut py) = (x, y);
    for _ in 0..octaves {
        sum += amp * perlin(px, py);
        amp *= gain;
        px *= lacunarity;
        py *= lacunarity;
    }
    sum
}

/// Re-exported for callers that want the unscaled 0..1-ish field.
pub fn water_level_normalized(h: f32) -> f32 {
    lerp_step(0.0, HEIGHT_MULTIPLIER, h)
}
