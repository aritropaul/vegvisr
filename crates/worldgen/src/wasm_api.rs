//! Thin wasm-bindgen surface. Everything is batched per tile — the JS/WASM
//! boundary is never crossed per pixel.

use crate::geo::WorldGenerator;
use crate::render::{Mode, Palette, TileRenderer};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub struct World {
    inner: TileRenderer,
    /// Placement and connectivity are both expensive (~7 s and ~55 ms) and both
    /// are wanted by more than one caller, so they are computed once on first
    /// demand and kept.
    placed: Option<Vec<crate::locations::Placed>>,
    gen_state: Option<crate::locations::GenState>,
    landmass: Option<crate::connect::Landmass>,
}

#[wasm_bindgen]
impl World {
    /// Builds the world and runs the one-time lake/river/stream pregeneration.
    #[wasm_bindgen(constructor)]
    pub fn new(seed_name: &str, world_gen_version: i32) -> World {
        let wg = WorldGenerator::from_seed_name(seed_name, world_gen_version);
        World { inner: TileRenderer::new(wg), placed: None, gen_state: None, landmass: None }
    }

    #[wasm_bindgen(getter)]
    pub fn seed(&self) -> i32 {
        self.inner.wg.seed
    }

    /// Rasterises a tile into wasm memory and returns the byte offset.
    /// The caller builds a Uint8ClampedArray view over `memory.buffer` at this
    /// pointer — re-derive it after every call, since growth detaches views.
    pub fn render_tile(
        &mut self,
        ox: f32,
        oy: f32,
        span: f32,
        size: usize,
        mode: u8,
        palette: u8,
    ) -> *const u8 {
        // Relief and contours were separate modes; they describe the same
        // thing and are now drawn together as Terrain. 2 is accepted as a
        // legacy alias for shared links.
        let mode = if mode == 0 { Mode::Biome } else { Mode::Terrain };
        let palette = if palette == 1 { Palette::Accessible } else { Palette::Classic };
        self.inner.render(ox, oy, span, size, mode, palette);
        self.inner.pixels().as_ptr()
    }

    /// Biome id at a world position (raw enum value).
    pub fn biome_at(&self, wx: f32, wy: f32) -> u16 {
        self.inner.wg.biome(wx, wy) as u16
    }

    /// Terrain height at a world position, in world Y units (sea level = 30).
    pub fn height_at(&self, wx: f32, wy: f32) -> f32 {
        self.inner.wg.height(wx, wy)
    }
}

#[wasm_bindgen]
impl World {
    /// Heights over an `nx` x `ny` lattice, row-major from the NORTH edge
    /// southward. One call instead of n*m boundary crossings.
    pub fn heights_grid(&self, ox: f32, oy: f32, span: f32, nx: usize, ny: usize) -> Vec<f32> {
        let mut out = Vec::with_capacity(nx * ny);
        for j in 0..ny {
            let wy = oy - (j as f32 + 0.5) * (span / ny as f32);
            for i in 0..nx {
                let wx = ox + (i as f32 + 0.5) * (span / nx as f32);
                out.push(self.inner.wg.height(wx, wy));
            }
        }
        out
    }

    /// Biome counts over a sampled lattice, indexed by biome ordinal.
    /// Samples outside the 10km playable disc are skipped — beyond it the
    /// generator still classifies terrain (as Ashlands, mostly), which would
    /// swamp the composition readout with area no player can reach.
    pub fn biome_histogram(
        &self,
        ox: f32,
        oy: f32,
        span_x: f32,
        span_y: f32,
        n: usize,
    ) -> Vec<u32> {
        let mut counts = vec![0u32; 10];
        for j in 0..n {
            let wy = oy - (j as f32 + 0.5) * (span_y / n as f32);
            for i in 0..n {
                let wx = ox + (i as f32 + 0.5) * (span_x / n as f32);
                if (wx * wx + wy * wy).sqrt() > 10000.0 {
                    continue;
                }
                let idx = match self.inner.wg.biome(wx, wy) {
                    crate::geo::Biome::None => 0,
                    crate::geo::Biome::Meadows => 1,
                    crate::geo::Biome::Swamp => 2,
                    crate::geo::Biome::Mountain => 3,
                    crate::geo::Biome::BlackForest => 4,
                    crate::geo::Biome::Plains => 5,
                    crate::geo::Biome::AshLands => 6,
                    crate::geo::Biome::DeepNorth => 7,
                    crate::geo::Biome::Ocean => 8,
                    crate::geo::Biome::Mistlands => 9,
                };
                counts[idx] += 1;
            }
        }
        counts
    }
}

#[wasm_bindgen]
impl World {
    /// Placed locations whose `Kind` is set in `kind_mask`, flattened as
    /// [kind, cfgIndex, x, y, reachable] per entry. `reachable` is 1 when the
    /// site shares the spawn landmass.
    ///
    /// Filtering here rather than in JS matters: a world holds ~12 000 sites
    /// but only a few hundred are ever switched on, and shipping the rest
    /// across the boundary costs a 240 KB copy plus the spatial index built
    /// over it. Placement itself still runs for every type — it cannot be
    /// filtered, because all types compete for the same 64 m zones and
    /// skipping one moves every location placed after it.
    pub fn locations_of(&mut self, kind_mask: u32) -> Vec<f32> {
        self.ensure_placed();
        let lm = self.landmass.as_ref().unwrap();
        let placed = self.placed.as_ref().unwrap();
        let mut out = Vec::new();
        for p in placed {
            let cfg = &crate::locations::LOCATIONS[p.cfg];
            if kind_mask & (1u32 << (cfg.kind as u8)) == 0 {
                continue;
            }
            out.push(cfg.kind as u8 as f32);
            out.push(p.cfg as f32);
            out.push(p.x);
            out.push(p.y);
            out.push(if lm.nearest_land(p.x, p.y, 6) == lm.spawn { 1.0 } else { 0.0 });
        }
        out
    }

    /// Per-category counts, so the UI can show totals for categories it has
    /// not fetched. 15 numbers instead of 12 000 records.
    pub fn location_counts(&mut self) -> Vec<u32> {
        self.ensure_placed();
        let mut counts = vec![0u32; 16];
        for p in self.placed.as_ref().unwrap() {
            counts[crate::locations::LOCATIONS[p.cfg].kind as u8 as usize] += 1;
        }
        counts
    }

    /// The headline facts people actually quote when they share a seed, as
    /// JSON: how big the starting landmass is, and for each boss and trader
    /// the nearest instance plus whether you can walk to it.
    pub fn report(&mut self) -> String {
        use crate::locations::{Kind, LOCATIONS};
        self.ensure_placed();
        let lm = self.landmass.as_ref().unwrap();
        let placed = self.placed.as_ref().unwrap();

        // Best instance per label: prefer one on the spawn landmass, then the
        // nearest. A boss you can walk to at 3 km beats one you must sail to
        // at 1 km, which is exactly how the community ranks them.
        let mut best: std::collections::BTreeMap<&str, (f32, bool, f32, f32, u8)> =
            Default::default();
        let mut counts = [0u32; 16];
        for p in placed {
            let c = &LOCATIONS[p.cfg];
            counts[c.kind as u8 as usize] += 1;
            if !matches!(c.kind, Kind::Boss | Kind::Trader) {
                continue;
            }
            let d = (p.x * p.x + p.y * p.y).sqrt();
            let same = lm.nearest_land(p.x, p.y, 6) == lm.spawn;
            let e = best.entry(c.label).or_insert((f32::MAX, false, 0.0, 0.0, c.kind as u8));
            if (same && !e.1) || (same == e.1 && d < e.0) {
                *e = (d, same, p.x, p.y, c.kind as u8);
            }
        }

        let mut sites = String::new();
        for (label, (d, same, x, y, kind)) in &best {
            if !sites.is_empty() {
                sites.push(',');
            }
            sites.push_str(&format!(
                "{{\"label\":\"{label}\",\"kind\":{kind},\"dist\":{d:.0},\"x\":{x:.0},\"y\":{y:.0},\"reachable\":{same}}}"
            ));
        }

        let mut largest = 0.0f32;
        for i in 0..lm.sizes.len() {
            largest = largest.max(lm.area_km2(i as i32));
        }
        let spawn_area = lm.area_km2(lm.spawn);
        let reach = best.values().filter(|v| v.1).count();
        format!(
            "{{\"spawnAreaKm2\":{spawn_area:.2},\"largestKm2\":{largest:.2},\"landmasses\":{},\"spawnIsLargest\":{},\"reachable\":{reach},\"total\":{},\"sites\":[{sites}],\"counts\":{:?}}}",
            lm.sizes.len(),
            (spawn_area - largest).abs() < 0.01,
            best.len(),
            &counts[..15],
        )
    }

    /// Places the next `types` location types and returns progress in 0..1.
    /// Placement is strictly sequential — one shared occupancy map, prioritised
    /// types first — so this is the only honest way to report progress on it.
    /// Prioritised types (every boss, trader and the start temple) come first,
    /// so the markers people navigate by land in the first couple of steps.
    pub fn locations_step(&mut self, types: usize) -> f32 {
        let st = self.gen_state.get_or_insert_with(crate::locations::begin);
        crate::locations::step(&self.inner.wg, st, types);
        if st.done() {
            self.placed = Some(std::mem::take(&mut st.placed));
            self.gen_state = None;
            return 1.0;
        }
        st.progress()
    }

    /// Everything placed so far, in the same layout as `locations()`.
    pub fn locations_snapshot(&mut self, kind_mask: u32) -> Vec<f32> {
        if self.landmass.is_none() {
            self.landmass = Some(crate::connect::build(&self.inner.wg));
        }
        let lm = self.landmass.as_ref().unwrap();
        let empty: Vec<crate::locations::Placed> = Vec::new();
        let placed = match (&self.placed, &self.gen_state) {
            (Some(p), _) => p,
            (None, Some(st)) => &st.placed,
            _ => &empty,
        };
        let mut out = Vec::new();
        for p in placed {
            let cfg = &crate::locations::LOCATIONS[p.cfg];
            if kind_mask & (1u32 << (cfg.kind as u8)) == 0 {
                continue;
            }
            out.push(cfg.kind as u8 as f32);
            out.push(p.cfg as f32);
            out.push(p.x);
            out.push(p.y);
            out.push(if lm.nearest_land(p.x, p.y, 6) == lm.spawn { 1.0 } else { 0.0 });
        }
        out
    }

    fn ensure_placed(&mut self) {
        if self.placed.is_none() {
            self.placed = Some(crate::locations::generate(&self.inner.wg));
        }
        if self.landmass.is_none() {
            self.landmass = Some(crate::connect::build(&self.inner.wg));
        }
    }
}

/// The location config table as JSON, so the UI can label markers without
/// duplicating the table.
#[wasm_bindgen]
pub fn location_table() -> String {
    let mut s = String::from("[");
    for (i, c) in crate::locations::LOCATIONS.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&format!(
            "{{\"label\":\"{}\",\"prefab\":\"{}\",\"kind\":{}}}",
            c.label, c.prefab, c.kind as u8
        ));
    }
    s.push(']');
    s
}

/// Seed phrase -> integer world seed, exposed for the UI.
#[wasm_bindgen]
pub fn seed_from_name(name: &str) -> i32 {
    crate::random::seed_from_name(name)
}

/// Scans a batch of candidate seeds against the given criteria and returns the
/// hits as JSON. Batched so the worker can report progress and stay
/// interruptible without the search holding a lock on the whole run.
#[wasm_bindgen]
pub fn search_batch(
    start: u32,
    count: u32,
    radius: f32,
    near_mask: u16,
    min_home_km2: f32,
    home_mask: u16,
) -> String {
    let c = crate::search::Criteria {
        radius,
        required_near_spawn: near_mask,
        min_home_km2,
        required_on_home: home_mask,
    };
    let mut out = String::from("[");
    for i in start..start + count {
        if let Some(h) = crate::search::evaluate(i, &c) {
            if out.len() > 1 {
                out.push(',');
            }
            out.push_str(&format!(
                "{{\"phrase\":\"{}\",\"seed\":{},\"homeKm2\":{:.1},\"biomes\":{}}}",
                h.phrase, h.seed, h.home_km2, h.biomes_on_home
            ));
        }
    }
    out.push(']');
    out
}

/// Biome bit for a name, so the UI can build masks without hardcoding the
/// enum's discriminants in two languages.
#[wasm_bindgen]
pub fn biome_bit(name: &str) -> u16 {
    crate::search::biome_bit(name)
}
