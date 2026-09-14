# Vegvisr — Valheim Seed Map

**[vegvisr.vercel.app](https://vegvisr.vercel.app)**

A client-side Valheim world map explorer. Type a seed phrase, get the map.
No backend, no upload, no queue — the entire world generator runs in your
browser as WebAssembly across a pool of workers.

Named for the *vegvísir*, the Norse wayfinder — and in Valheim, the runestone
that reveals locations on your map.

```
bun install
bun run build:wasm   # requires: rustup target add wasm32-unknown-unknown
bun run dev          # -> https://valheim.lcl
```

## Why this is fast

The established tool in this space (valheim-map.world) ships a ~12 MB
**single-threaded Unity WebGL runtime** (`"multithreading": false`, per its own
build manifest) and takes 10–60 s per seed with the tab frozen, topping out at
8192² ≈ 2.44 m/px.

It does that because of a specific belief, stated on its about page: Unity's
random primitives are *"proprietary to Unity and their source code is not
released"*, so the only way to match the game is to run real Unity.

That premise is false. `UnityEngine.Random` is a xorshift128 with an MT19937-style
seeding constant, and `Mathf.PerlinNoise` is Ken Perlin's 2002 improved noise with
two Unity quirks. Both are reproduced here bit-for-bit and verified against
captured Unity output. Removing the Unity dependency is what removes the server,
the download, and the wait.

| | valheim-map.world | this |
|---|---|---|
| Engine | Unity WebGL, ~12 MB | Rust → WASM, **52 KB** |
| Threads | 1 | `hardwareConcurrency − 1` |
| Time to first map | 10–60 s, tab frozen | ~1 s, progressive |
| Max resolution | 2.44 m/px | **0.32 m/px** |
| Backend | required for some flows | none |

Measured on an M5 (native, single core): world pregeneration 135 ms, a 512²
biome tile 16 ms, a 512² biome+height tile 38 ms.

## Views

Two modes, one look: everything is drawn as luminous ink over a near-black
ground. Biome identity is carried by hue, terrain by relief and contour lines.

**BIOME** — soft luminous biome fields with gradient borders and only a
whisper of relief, so regions read as regions.

**TERRAIN** — the same fields under a two-light hillshade with iso-contours
drawn over them. Relief and contours were separate modes; they describe the
same thing, so they are drawn together.

Both share one sampling pass that fills an apron grid of (biome, height), so
neighbours are always real samples — which is what makes biome-edge blending
and relief normals seamless across tile borders.

**Contours** are measured relative to sea level, so the shoreline always lands
exactly on a line. Line width is normalised by the local height gradient,
keeping lines ~1 px whether they cross a flat or a cliff; without that, flats
go blank and cliffs turn into solid blocks. The interval snaps to a 1/2/5
ladder calibrated to Valheim's gentle slopes rather than to zoom alone.

**Borders are gradients, not steps.** Only the hue field is blurred — a
separable running-sum box blur, O(1) per pixel regardless of radius — so biome
regions fade into each other while hillshade, contours and the shoreline stay
pixel-crisp.

The blend width is anchored to a fixed **ground distance**, not a pixel count.
A fixed pixel radius is wrong at both ends: zoomed in it is invisible, and
zoomed out it is wider than the biome patches themselves, so a region gets
averaged with its neighbours until the colour on screen no longer matches the
biome actually at that pixel.

One trap worth recording, because it looks like the right fix and is not:
biasing each pixel back toward its *own* biome's pure hue seems like it would
protect region interiors. It does — but the pure hue flips at the boundary, so
each side pulls toward a different colour and the single smooth ramp becomes
two half-ramps with a step between them. It re-sharpens the exact edge the blur
exists to soften. The blurred field alone already gives both properties:
continuous across a boundary, and equal to the pure hue in any interior wider
than the radius.

**Water is a blend, not a threshold.** A hard `h < seaLevel` test dithers
badly: terrain roughness is about ±2 m, so ground near sea level flickers pixel
to pixel. Swamp is the worst case — it generates at ~27 m, just *under* sea
level — so marsh is additionally capped, because it is ankle-deep bog rather
than sea.

**Submerged ground reads as water.** Terrain below sea level is still
*classified* as Meadows, Black Forest and so on, so painting it with its biome
hue makes a drowned shelf look like land that simply forgot its coastline —
outlined in some places and not others. Hue blends toward the ocean ink with
depth, and water is muted hard so land carries the image.

The shoreline stroke is drawn where the **wetness field crosses 0.5**, not
where raw height crosses sea level. Height is the wrong signal: marsh generates
at ~27 m and oscillates across sea level, so a height test fires all over the
bog and speckles it. Suppressing the stroke per-biome fixes the speckle but
then loses the swamp's genuine coast, which is a real land/water edge. Because
wetness already caps marsh below 0.5, the bog interior never crosses the
threshold while the coast — where open water reaches 1.0 — always does. One
rule, no biome special-case.

**STD** uses naturalistic hues — grassy meadows, dark forest green, muddy
swamp, sandy plains — lifted to luminances that read against black. **A11Y**
separates every biome by hue *and* luminance; Mountain and Deep North are both
pale otherwise, which no existing tool addresses.

## 3D

`3D` lifts the current view into a displaced terrain surface, textured with
whichever mode is active. Hand-rolled WebGL2 rather than a scene graph: the job
is one displaced grid with one texture, and a 3D library would outweigh the
entire rest of the bundle.

- **Free camera.** Drag orbits, right- or shift-drag pans across the ground
  plane, WASD flies, wheel dollies, `R` recentres. Pitch goes down to the
  horizon for a ground-level landscape view.
- **The whole world is always on screen.** Detail is a nested clipmap, not a
  single patch. An earlier version loaded one patch and swapped it for a
  tighter one as you zoomed, which meant zooming in deleted the rest of the
  world — you flew around a floating square. Raising that one patch's
  resolution cannot fix it either: 21 km at 2 m per vertex is 100 M vertices.
  Instead the surface is a stack of levels sharing one centre. The coarsest
  spans the world; each finer level halves the span at the same vertex count,
  doubling resolution. Every level but the finest is drawn as a ring with its
  middle removed, so levels never overlap and screen-space triangle density
  stays roughly constant.
- **The hole goes where the finer level actually is.** Each level snaps to its
  own cell size so its edges don't crawl as the camera moves, which means
  levels do *not* share a centre. Punching the hole at the parent's centre
  leaves a gap on one side and a double-drawn strip on the other.
- **Skirts close the seams.** Two levels sample the same boundary at different
  resolutions, so their edges disagree by a fraction of a cell and hairline
  gaps show through to the background. Each level hangs a curtain from its
  outer edge; it is hidden behind the surface from any normal angle.
- **Sea is a flat plane.** Terrain clamps at sea level so land rises out of
  water the way a physical relief model reads.
- **Anisotropic filtering** is what makes the near-horizontal view work; at
  grazing angles plain mipmapping collapses the surface into mush.
- Telemetry raycasts the pointer against the height field (march, then
  bisect), so no GPU depth readback is needed. Markers project through the same
  matrix and are culled to the loaded patch.

## Points of interest

`MARKERS` toggles eight categories — spawn, bosses, traders, crypts, camps,
caves, mines, fortresses — drawn as flat geometric symbology rather than
map-app pins, each with a dark halo so it survives white mountains and pale
ice. Hovering a marker names it; boss/trader/spawn labels pin open once zoomed
in. ~1 820 sites for a typical seed, computed in ~1 s.

Placement parameters are transcribed from Jötunn's auto-generated location
list, which is dumped from a running game. Worth knowing when comparing
against other sources:

- **"Edge Median" means Everything.** It is a bitmask (`Edge|Median`), not a
  third state. Only six types are genuinely Median-only, and those really are
  restricted to zones whose eight neighbours all share the biome.
- **No location has a max distance.** Bosses are spread across their whole
  biome, not confined to an inner ring.
- **Traders have quantity 10, not 1.** The game places ten candidate camps and
  only the first a player visits ever instantiates a vendor — which is why map
  tools show multiple trader markers.
- **`m_unique` does not cap the loop.** It is checked once *before* placement
  begins, to skip regeneration on an existing world.

This is a port of `ZoneSystem.GenerateLocations`, and two things make it
harder than it looks:

- **The RNG draw order is load-bearing.** `GetTerrainDelta` alone consumes 20
  values (10 `insideUnitCircle` calls, a closed-form polar method drawing 2
  each), and it is only reached when the cheaper checks above it pass.
  Reorder the checks and every position downstream changes. Some community
  tools treat `insideUnitCircle` as unrecoverable and substitute a fixed
  sample ring; it is recoverable, and it is exactly 2 draws.
- **Locations cannot be generated independently.** There is one shared
  occupancy map — one location per 64 m zone, globally, across all types —
  and prioritised types are placed first, so a boss altar can block a crypt.

## Architecture

```
crates/worldgen/          Rust world generator (the whole algorithm)
  random.rs               UnityEngine.Random + GetStableHashCode
  perlin.rs               Mathf.PerlinNoise
  geo.rs                  GetBiome / GetBaseHeight
  heights.rs              per-biome height functions
  rivers.rs               lakes, rivers, streams (Pregenerate)
  render.rs               tile rasterisation + palettes
src/
  workers/tile.worker.ts  one WASM instance per worker
  core/pool.ts            worker pool, priority queue, dedup, cancellation
  core/cache.ts           LRU ImageBitmap cache
  render/map.ts           pan/zoom, quadtree LOD, progressive refinement
```

Three decisions worth recording, each of which was researched rather than guessed:

**Generation runs on the CPU, not the GPU.** A fragment shader would be much
faster per pixel, and it is the wrong tool. `GetBiome` is a chain of threshold
comparisons against Perlin values (`> 0.6`, `> 0.4`, …). GPUs are not required to
be IEEE-754 conformant — FMA contraction and operation reordering differ per
driver — so ULP-level divergence flips biome classification on boundary pixels,
producing coastlines that are subtly wrong and *differ per GPU vendor*. The
existing tools all generate on the CPU for the same reason.

**Workers hold independent, non-shared WASM instances.** No `SharedArrayBuffer`,
so no COOP/COEP headers, so this deploys to any static host including GitHub
Pages. Tile generation is embarrassingly parallel at the tile level anyway, so
the finer-grained parallelism `wasm-bindgen-rayon` would buy isn't needed — and
it would cost a nightly Rust toolchain and cross-origin isolation.

**SIMD is not used for the noise, deliberately.** The build already enables
`simd128`, and base WASM SIMD is spec-required to be IEEE-754 exact per lane
with no FMA, so vectorising four pixels at once would keep Unity parity. The
arithmetic is worth it on paper — measured, `perlin()` is 7.6 ns and accounts
for ~72% of a biome classification (106 ns) and most of a height sample
(321 ns).

It is still not worth doing. The dominant cost in this tool is location
placement at ~7 s, and that cannot be vectorised: candidates come off an RNG
stream one at a time and each is accepted or rejected before the next is drawn.
The paths that *can* batch — tile rendering, connectivity, seed search — are
already fast enough that a ~1.3-1.5x would not change how anything feels. And
Perlin's `PERM` lookups are data-dependent gathers that WASM SIMD cannot do,
which is where that modest ceiling comes from. Rewriting the one function whose
bit-exactness the whole project rests on, for that, is a bad trade. It becomes
a good trade only if batch rendering ever becomes the bottleneck.

**wasm-pack is not used.** The `rustwasm` org was archived in 2025; the build
drives `cargo` + `wasm-bindgen-cli` + `wasm-opt` directly.

## Accuracy

Verified against ground truth, not assumed:

- **Perlin** — matches 176 values dumped from real `UnityEngine.Mathf.PerlinNoise`,
  max error 2.3e-7. Includes Unity's two quirks: inputs pass through `abs()`
  (so the field is mirrored across both axes), and the result is rescaled by
  `(raw + 0.69) / 1.483`. A textbook Perlin implementation silently fails here.
- **RNG** — reproduces Unity-captured state and output vectors for seed 1234.
  `Range(int,int)` uses plain 64-bit modulo with *no* rejection sampling, so it
  reproduces Unity's modulo bias; "fixing" that would make it wrong.
- **Biome distribution** — Ashlands lands at 9.50% of world area, matching an
  independent community measurement of ~9.5% across six real seeds. Mistlands
  falls inside the independently measured 18.4–19.5% band.
- **Draw order** — `offset0..3`, `riverSeed`, `streamSeed`, **`offset4` last**.
  Easy to get wrong, silently produces a different world.

### Precision is part of the algorithm

Valheim's generator is not uniformly single-precision, and treating it as if it
were is a quiet source of error. Three places where the width is load-bearing:

- **`GetBaseHeight` accumulates coordinates in `double`** — `double num5 = wx;
  num5 += 100000.0 + (double)m_offset0;` — with no narrowing before the noise
  call. Every *per-biome* height function does the opposite, casting back to
  float first. Doing base height in f32 throughout costs up to 1 cm of terrain
  height and flips about one pixel in 400 000 across a biome threshold, and
  those pixels land on coastlines.
- **`DUtils.Length` squares and sums in `double`** before the square root. In
  f32 the sum reaches ~2e8 at world-edge distances where the representable step
  is ~16, so the radius is wrong by enough to land on the wrong side of the
  `dist > 2000` biome-radius comparisons.
- **`DUtils.Lerp` clamps at both ends and interpolates as `a*(1-t) + b*t`**, not
  the usual `a + (b-a)*t`. The two forms disagree in the last bits.

None of these is visible in a screenshot. All of them move biome boundaries.

### Known limitations

These are real and worth stating plainly:

1. **Targets pre-1.0 world generation (`m_worldGenVersion = 2`).** The terrain
   math here is transcribed from a decompile of **0.218.15** — the Ashlands
   release. Valheim 1.0 shipped 2026-09-09 as the Deep North update and bumped
   the world version; no 1.0 decompile is public yet. The location table *has*
   been checked against 1.0.7 (see below) and matches, and the core terrain
   functions were byte-stable across every build from 0.216.5 to 0.221.12, so
   1.0 terrain is likely still correct — but "likely" is not "verified".
2. **Deep North terrain is the pre-1.0 shape.** Its ocean gap and biome
   placement are exact, but 1.0 turned Deep North from a placeholder band into
   finished content, and that work postdates the decompile available here.
3. **Vegetation — trees, ore, berries — is not generated.** The algorithm is
   now known: `ZoneSystem.PlaceVegetation` seeds per zone and prefab with
   `InitState(seed + zoneID.x * 4271 + zoneID.y * 9187 + hash(prefabName))`,
   which confirms vegetation is a pure function of the world seed and needs no
   runtime state. The `ZoneVegetation` table is published alongside the
   location table. So the blocker is no longer "how does it work".

   It is that two of the per-candidate rejection tests cannot be reproduced
   from the seed alone:

   - `GetGroundData` takes the ground normal from a **physics raycast against
     the built terrain collider**, and the tilt test compares it to
     `cos(m_maxTilt)`. Copper wants 5–45° and silver 0–30°, so both depend on
     a mesh this tool does not build. Tin and obsidian are unconstrained
     (0–90°) and would be unaffected.
   - `IsBlocked` rejects a candidate that collides with something already
     spawned in that zone. That needs every prefab's collider extents, which
     live in the asset bundles, and it is order-dependent across prefabs.
     Jötunn's dump does not even expose which entries set `m_blockCheck`.

   A layer built without those would be *candidate* sites, not ore — right
   where nothing rejected them, silently wrong where something did. For a tool
   whose claim is bit-exactness that is worse than showing nothing, so it
   shows nothing.

4. **The location table is transcribed, not extracted.** Placement parameters
   live in Unity asset bundles rather than the game DLL, so they cannot be read
   out of a decompile. The table here is transcribed from Jötunn's
   auto-generated dump of a running game. The algorithm is verified by tests;
   the data is only as current as that dump.

## Testing

```
cd crates/worldgen && cargo test --release
```

Developed and checked against seed `j3QV2ftr3y`, which is the default in the
UI and `TEST_SEED` in the suite.

17 tests covering Unity RNG and hash vectors, the 176-sample Perlin ground
truth, the mirror-symmetry quirk, seed→offset draw order, biome distribution
against independent measurements, determinism, pole orientation, world-edge
falloff, and — for locations — that every type places at least one, that
placements respect their biome and distance constraints, and that no two
locations ever share a 64 m zone. One test renders a tile and asserts land
pixels are painted their own biome's colour — measured over *all* land rather
than region interiors, because an interiors-only check passes even with a
wildly over-wide boundary blend.
