//! Tile rasterisation: world coordinates -> RGBA pixels.
//!
//! Two modes, one look. Everything is drawn as luminous ink over a near-black
//! ground: biome identity is carried by hue, terrain by relief and contour
//! lines. Both modes share one sampling pass that fills an apron grid of
//! (biome, height), which is what lets biome borders blur and relief normals
//! stay seamless across tile edges.

use crate::geo::{Biome, WorldGenerator, WATER_LEVEL};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Biome fields: soft luminous regions with gradient borders.
    Biome = 0,
    /// Terrain: relief shading with iso-contours over the same fields.
    /// (Relief and contours were separate modes; they describe the same thing,
    /// so they are drawn together.)
    Terrain = 1,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Palette {
    /// Naturalistic hues, rendered emissively.
    Classic = 0,
    /// Hue *and* luminance separated for red-green colour blindness.
    Accessible = 1,
}

type Rgb = [f32; 3];

const fn rgb(r: f32, g: f32, b: f32) -> Rgb {
    [r, g, b]
}

/// Ground the whole map sits on.
const BACKDROP: Rgb = rgb(5.0, 8.0, 16.0);
const SHORE: Rgb = rgb(126.0, 232.0, 255.0);

/// Emissive ink per biome. Hues follow the terrain as it actually looks —
/// grassy meadows, dark forest, muddy swamp, sandy plains — but lifted to
/// luminances that read against a near-black ground.
#[inline]
fn ink(b: Biome, p: Palette) -> Rgb {
    match p {
        Palette::Classic => match b {
            Biome::Meadows => rgb(168.0, 224.0, 95.0),     // light grassy green
            Biome::BlackForest => rgb(47.0, 125.0, 79.0),  // dark forest green
            Biome::Swamp => rgb(154.0, 123.0, 69.0),       // muddy brown
            Biome::Plains => rgb(217.0, 184.0, 118.0),     // sandy brown
            Biome::Mountain => rgb(220.0, 233.0, 242.0),
            Biome::Mistlands => rgb(138.0, 123.0, 200.0),
            Biome::AshLands => rgb(224.0, 85.0, 47.0),
            Biome::DeepNorth => rgb(159.0, 216.0, 240.0),
            Biome::Ocean => rgb(38.0, 84.0, 196.0),
            Biome::None => rgb(120.0, 120.0, 120.0),
        },
        // Pushed apart in hue AND luminance so the greens and the two pale
        // biomes stay separable without colour discrimination.
        Palette::Accessible => match p2_guard(b) {
            Biome::Meadows => rgb(198.0, 240.0, 96.0),
            Biome::BlackForest => rgb(40.0, 158.0, 220.0),
            Biome::Swamp => rgb(244.0, 118.0, 206.0),
            Biome::Plains => rgb(246.0, 196.0, 62.0),
            Biome::Mountain => rgb(255.0, 255.0, 255.0),
            Biome::Mistlands => rgb(176.0, 128.0, 255.0),
            Biome::AshLands => rgb(255.0, 128.0, 54.0),
            Biome::DeepNorth => rgb(126.0, 226.0, 255.0),
            Biome::Ocean => rgb(58.0, 104.0, 226.0),
            Biome::None => rgb(140.0, 140.0, 140.0),
        },
    }
}

#[inline]
fn p2_guard(b: Biome) -> Biome {
    b
}

/// How wet a sample is, 0 = dry land, 1 = open water.
///
/// A hard `h < WATER_LEVEL` test dithers badly: terrain roughness is about
/// +/-2 m, so ground near sea level flickers pixel to pixel. Swamp is the
/// worst case — it generates at ~27 m, just under sea level — so marsh is
/// additionally capped, because it is ankle-deep bog rather than sea.
#[inline]
fn wetness(h: f32, b: Biome) -> f32 {
    let w = smooth_step_f(WATER_LEVEL + 2.0, WATER_LEVEL - 2.5, h);
    if b == Biome::Swamp {
        w.min(0.30)
    } else {
        w
    }
}

/// Apron width, sized for the widest blend radius we ever use.
const PAD: usize = 14;

/// Biome boundaries blend over this many WORLD METRES, not a fixed pixel
/// count.
///
/// A fixed pixel radius is wrong at both ends: zoomed in it is invisible, and
/// zoomed out it is wider than the biome patches themselves, so a region gets
/// averaged with its neighbours until the colour on screen no longer matches
/// the biome actually at that pixel. Anchoring the blend to ground distance
/// keeps regions true at every scale — crisp when a patch is only a few pixels
/// across, soft when you are close enough to see the transition.
const BLEND_METRES: f32 = 120.0;

/// Blur radius for one box pass. Two passes per axis compose into a tent of
/// half-width `2 * r`, so this is the target half-width halved.
/// Two box passes per axis compose into a tent whose full ramp is `4 * r`
/// pixels, so solve that for the target ground distance.
#[inline]
fn blend_radius(metres_per_px: f32) -> usize {
    ((BLEND_METRES / (4.0 * metres_per_px)).round() as usize).clamp(1, PAD / 2)
}

pub struct TileRenderer {
    pub wg: WorldGenerator,
    pixels: Vec<u8>,
    heights: Vec<f32>,
    biomes: Vec<u8>,
    /// Per-sample biome ink, and its blurred copy. Only the hue field is
    /// blurred; shading and contours are computed per-pixel afterwards so they
    /// stay crisp while region boundaries gradient.
    hue: Vec<f32>,
    hue_blur: Vec<f32>,
    size: usize,
}

#[inline]
fn ord(b: Biome) -> u8 {
    match b {
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
    }
}

#[inline]
fn unord(o: u8) -> Biome {
    match o {
        1 => Biome::Meadows,
        2 => Biome::Swamp,
        3 => Biome::Mountain,
        4 => Biome::BlackForest,
        5 => Biome::Plains,
        6 => Biome::AshLands,
        7 => Biome::DeepNorth,
        8 => Biome::Ocean,
        9 => Biome::Mistlands,
        _ => Biome::None,
    }
}

impl TileRenderer {
    pub fn new(wg: WorldGenerator) -> Self {
        Self {
            wg,
            pixels: Vec::new(),
            heights: Vec::new(),
            biomes: Vec::new(),
            hue: Vec::new(),
            hue_blur: Vec::new(),
            size: 0,
        }
    }

    fn ensure(&mut self, size: usize) {
        if self.size != size {
            let w = size + 2 * PAD;
            self.pixels = vec![0u8; size * size * 4];
            self.heights = vec![0f32; w * w];
            self.biomes = vec![0u8; w * w];
            self.hue = vec![0f32; w * w * 3];
            self.hue_blur = vec![0f32; w * w * 3];
            self.size = size;
        }
    }

    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }

    /// Separable blur of the hue field using running-sum box passes: O(1) per
    /// pixel regardless of radius. Two passes per axis compose into a tent,
    /// which ramps without the flat-topped banding a single box leaves.
    fn blur_hue(&mut self, w: usize, r: usize) {
        for _ in 0..2 {
            box_h(&self.hue, &mut self.hue_blur, w, r);
            std::mem::swap(&mut self.hue, &mut self.hue_blur);
        }
        for _ in 0..2 {
            box_v(&self.hue, &mut self.hue_blur, w, r);
            std::mem::swap(&mut self.hue, &mut self.hue_blur);
        }
    }

    /// Rasterise one square tile. `ox` is the west edge and `oy` the NORTH
    /// edge; rows advance southward so north renders upward on screen.
    pub fn render(&mut self, ox: f32, oy: f32, span: f32, size: usize, mode: Mode, palette: Palette) {
        self.ensure(size);
        let step = span / size as f32;
        let n = size;
        let hw = n + 2 * PAD;

        for gy in 0..hw {
            let wy = oy - (gy as f32 - PAD as f32) * step;
            for gx in 0..hw {
                let wx = ox + (gx as f32 - PAD as f32) * step;
                let (b, base) = self.wg.biome_with_base(wx, wy);
                let i = gy * hw + gx;
                self.biomes[i] = ord(b);
                self.heights[i] = self.wg.biome_height_with_base(b, wx, wy, base);
                let c = ink(b, palette);
                self.hue[i * 3] = c[0];
                self.hue[i * 3 + 1] = c[1];
                self.hue[i * 3 + 2] = c[2];
            }
        }
        self.blur_hue(hw, blend_radius(step));

        let contours = mode == Mode::Terrain;
        let interval = contour_interval(step);

        for py in 0..n {
            for px in 0..n {
                let gi = (py + PAD) * hw + (px + PAD);
                let b = unord(self.biomes[gi]);
                let h = self.heights[gi];
                let wet = wetness(h, b);
                // The blurred field is used directly: across a boundary it is
                // one continuous ramp, and in a region interior it already
                // equals that biome's own colour.
                //
                // Do NOT bias each pixel back toward its own pure hue here.
                // That looks like it would protect interiors, but the pure hue
                // flips at the boundary, so each side pulls toward a different
                // colour and the single smooth ramp becomes two half-ramps
                // with a step between them — re-sharpening the exact edge the
                // blur exists to soften. Interiors are protected by the blend
                // radius being anchored to world distance instead.
                let hue = [self.hue[gi * 3], self.hue[gi * 3 + 1], self.hue[gi * 3 + 2]];

                let dzdx = (self.heights[gi + 1] - self.heights[gi - 1]) * 0.5;
                let dzdy = (self.heights[gi + hw] - self.heights[gi - hw]) * 0.5;
                let grad = (dzdx * dzdx + dzdy * dzdy).sqrt().max(1e-4);

                // Submerged ground reads as water, not as a dim version of
                // its biome. Terrain below sea level is still *classified* as
                // Meadows, Black Forest and so on, so without this a drowned
                // shelf paints dark green and looks like land that simply
                // forgot its coastline.
                let depth_t = ((WATER_LEVEL - h).max(0.0) / 100.0).clamp(0.0, 1.0);
                let sea = ink(Biome::Ocean, palette);
                let hue = [
                    hue[0] + (sea[0] - hue[0]) * wet,
                    hue[1] + (sea[1] - hue[1]) * wet,
                    hue[2] + (sea[2] - hue[2]) * wet,
                ];

                // Water is muted hard so land carries the whole image and the
                // coastline is the strongest contrast edge on the map.
                let land_gain;
                let water_gain = 0.20 - depth_t * 0.115;

                let mut out = [0f32; 3];

                if contours {
                    // Two-light hillshade. A single lamp flattens ridges
                    // running parallel to it; a dimmer opposite fill recovers
                    // them.
                    let z_exag = (step * 0.6).max(1.0);
                    let nx = -dzdx * z_exag / step;
                    let ny = -dzdy * z_exag / step;
                    let inv = 1.0 / (nx * nx + ny * ny + 1.0).sqrt();
                    let key = ((nx * -0.62 + ny * -0.62 + 1.0) * inv).clamp(0.0, 1.8);
                    let fill = ((nx * 0.5 + ny * 0.55 + 1.0) * inv).clamp(0.0, 1.8);
                    let slope = (nx * nx + ny * ny).sqrt().min(2.5);
                    let ao = 1.0 - (slope * 0.16).min(0.34);
                    land_gain = (0.20 + key * 0.34 + fill * 0.10) * ao;
                } else {
                    // Flat fields with only a whisper of relief, so regions
                    // read as regions.
                    let emboss = ((dzdx + dzdy) / (step * 2.2)).clamp(-0.6, 0.6);
                    land_gain = 0.40 * (1.0 + emboss * 0.22);
                }

                let gain = land_gain + (water_gain - land_gain) * wet;
                for k in 0..3 {
                    out[k] = BACKDROP[k] + hue[k] * gain;
                }

                if contours {
                    // Contours relative to sea level, so the shoreline always
                    // lands exactly on a line. Line width is normalised by the
                    // local gradient, keeping lines ~1px on flats and cliffs
                    // alike.
                    let rel = h - WATER_LEVEL;
                    let minor = line_strength(rel, interval, grad, 0.75);
                    let major = line_strength(rel, interval * 5.0, grad, 1.35);
                    let sink = 1.0 - wet * 0.66;
                    let glow = ((minor * 0.34 + major * 0.72) * sink).min(1.3);
                    for k in 0..3 {
                        out[k] += hue[k] * glow;
                    }
                }

                // Shoreline stroke, drawn where the WETNESS field crosses 0.5
                // rather than where raw height crosses sea level.
                //
                // Height is the wrong signal: marsh generates at ~27 m and
                // oscillates across sea level, so a height test fires all over
                // the bog and speckles it. Suppressing it per-biome then loses
                // the swamp's genuine coast, which is a real land/water edge.
                // Wetness already caps marsh below 0.5, so the interior never
                // crosses the threshold while the coast — where open water
                // reaches 1.0 — always does. One rule, no biome special-case.
                let wl = wetness(self.heights[gi - 1], unord(self.biomes[gi - 1]));
                let wr = wetness(self.heights[gi + 1], unord(self.biomes[gi + 1]));
                let wu = wetness(self.heights[gi - hw], unord(self.biomes[gi - hw]));
                let wd = wetness(self.heights[gi + hw], unord(self.biomes[gi + hw]));
                let gwx = (wr - wl) * 0.5;
                let gwy = (wd - wu) * 0.5;
                let gw = (gwx * gwx + gwy * gwy).sqrt().max(1e-4);
                let shore = 1.0 - smooth_step_f(0.0, 1.4, (wet - 0.5).abs() / gw);
                for k in 0..3 {
                    out[k] += SHORE[k] * shore * 0.55;
                }

                let g = grain(px, py);
                let i = (py * n + px) * 4;
                for k in 0..3 {
                    self.pixels[i + k] = (out[k] + g).clamp(0.0, 255.0) as u8;
                }
                self.pixels[i + 3] = 255;
            }
        }
    }
}

/// Horizontal running-sum box blur over an RGB f32 field.
fn box_h(src: &[f32], dst: &mut [f32], w: usize, r: usize) {
    let n = (2 * r + 1) as f32;
    for y in 0..w {
        let row = y * w;
        let mut acc = [0f32; 3];
        for x in 0..=(2 * r).min(w - 1) {
            for c in 0..3 {
                acc[c] += src[(row + x) * 3 + c];
            }
        }
        for x in r..w - r {
            for c in 0..3 {
                dst[(row + x) * 3 + c] = acc[c] / n;
            }
            if x + r + 1 < w {
                for c in 0..3 {
                    acc[c] += src[(row + x + r + 1) * 3 + c] - src[(row + x - r) * 3 + c];
                }
            }
        }
    }
}

/// Vertical running-sum box blur over an RGB f32 field.
fn box_v(src: &[f32], dst: &mut [f32], w: usize, r: usize) {
    let n = (2 * r + 1) as f32;
    for x in 0..w {
        let mut acc = [0f32; 3];
        for y in 0..=(2 * r).min(w - 1) {
            for c in 0..3 {
                acc[c] += src[(y * w + x) * 3 + c];
            }
        }
        for y in r..w - r {
            for c in 0..3 {
                dst[(y * w + x) * 3 + c] = acc[c] / n;
            }
            if y + r + 1 < w {
                for c in 0..3 {
                    acc[c] += src[((y + r + 1) * w + x) * 3 + c] - src[((y - r) * w + x) * 3 + c];
                }
            }
        }
    }
}

/// Faint dither so large flats don't band.
#[inline]
fn grain(px: usize, py: usize) -> f32 {
    let mut h = (px as u32).wrapping_mul(0x9E37_79B9) ^ (py as u32).wrapping_mul(0x85EB_CA6B);
    h ^= h >> 15;
    h = h.wrapping_mul(0xC2B2_AE35);
    h ^= h >> 13;
    ((h & 0xFF) as f32 / 255.0 - 0.5) * 3.0
}

/// Contour interval landing roughly 12-20 px apart on screen, calibrated to
/// Valheim's gentle slopes rather than zoom alone.
fn contour_interval(meters_per_px: f32) -> f32 {
    let target = meters_per_px * 1.4;
    let mag = 10f32.powf(target.max(1.0).log10().floor());
    let norm = target / mag;
    let snapped = if norm < 1.5 {
        1.0
    } else if norm < 3.5 {
        2.0
    } else if norm < 7.5 {
        5.0
    } else {
        10.0
    };
    (snapped * mag).max(2.0)
}

#[inline]
fn line_strength(h: f32, interval: f32, grad: f32, width_px: f32) -> f32 {
    let t = h / interval;
    let f = t - t.floor();
    let dist_px = f.min(1.0 - f) * interval / grad;
    1.0 - smooth_step_f(0.0, width_px, dist_px)
}

#[inline]
fn smooth_step_f(lo: f32, hi: f32, x: f32) -> f32 {
    let t = ((x - lo) / (hi - lo)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}
