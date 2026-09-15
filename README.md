# Vegvisr

[![ci](https://github.com/aritropaul/vegvisr/actions/workflows/ci.yml/badge.svg)](https://github.com/aritropaul/vegvisr/actions/workflows/ci.yml)

**[vegvisr.vercel.app](https://vegvisr.vercel.app)** — a Valheim seed map that
runs entirely on your own machine, in the browser or as a native Mac and
iPhone app.

Type a seed phrase and the whole world appears: biomes, terrain, rivers, and
12 000 points of interest, down to 0.32 m per pixel. There is no backend, no
upload step and no queue. Valheim's world generator is reimplemented twice — in
Rust for the web, compiled to 62 KB of WebAssembly, and in Swift for the Apple
app — and run across a pool of workers on your own machine.

Named for the *vegvísir*, the Norse wayfinder — and in Valheim, the runestone
that reveals locations on your map.

**Web**

```
cd web
bun install
bun run build:wasm   # needs: rustup target add wasm32-unknown-unknown
bun run dev
```

**Mac and iPhone**

```
cd apple
xcodegen generate    # needs: brew install xcodegen
open Vegvisr.xcodeproj
```

The Xcode project is generated, not committed, and the app is ad-hoc signed, so
a fresh clone builds and runs with no Apple ID. Shipping to a device needs a
`DEVELOPMENT_TEAM` in a git-ignored `apple/Local.xcconfig`.

## What it does

- **2D map** — biome and terrain views, gradient biome borders, sea-level
  contours, shaded relief.
- **3D** — the same world as a displaced surface with a nested clipmap, so the
  whole map stays on screen while the ground under the camera stays sharp.
- **12 006 points of interest** across 183 location types, in 15 toggleable
  categories: bosses, traders, crypts, runestones, drake nests, shipwrecks,
  villages, and the rest.
- **Seed report** — how big your starting landmass is and, for every boss and
  trader, whether you can walk there or need a boat.
- **Seed search** — scan for a seed by what is on its starting landmass.
- **Ruler, search, permalinks** — measure a sailing route, jump to a location
  by name or coordinate, share a link to an exact view.
- **Drop a `.fwl`** world file to load its seed without retyping it.
- **A native Mac and iPhone app** — the same map and the same look, in Swift
  and Metal, with no Rust and no WebAssembly anywhere in it.

## Why it is fast

The established tool in this space, [valheim-map.world][vmw], ships a Unity
WebGL build. That is a deliberate choice, and its stated reason is a specific
technical belief: that Unity's random primitives are *"proprietary to Unity and
their source code is not released"*, so the only way to reproduce the game
exactly is to run real Unity.

That premise is false, and falsifying it is what this project is.
`UnityEngine.Random` is a xorshift128 with an MT19937-style seeding constant,
and `Mathf.PerlinNoise` is Ken Perlin's 2002 improved noise with two Unity
quirks. Both are reproduced here bit-for-bit and verified against captured
Unity output and against real Valheim save files. Removing the Unity dependency
is what removes the 12 MB download, the single thread, and the wait.

[vmw]: https://valheim-map.world

## Compared with valheim-map.world

valheim-map.world came first, is free, is donation-funded, and is the reason
this community can look up a seed at all. It also does things this does not:
collaborative lobbies with shared custom pins, full world-file upload, map
image export, and a fog-of-war layer. If you want those, use it.

Everything below was verified directly against the live site and its own build
manifest in September 2026, not taken from its documentation.

| | valheim-map.world | Vegvisr |
|---|---|---|
| Engine | Unity 2019 WebGL | Rust → WebAssembly |
| Valheim 1.0 | yes, beta since 2026-09-11 | yes — world version 2, location table from a live 1.0.7 dump |
| Download | **12.5 MB** <sup>1</sup> | **216 KB** (86 KB gzipped) |
| Threads | **1** <sup>2</sup> | `~60% of cores` |
| Revisiting a seed | regenerates | **generates nothing** <sup>3</sup> |
| Search by name | no | yes |
| Measure distance | no | yes |
| Landmass reachability | no | yes |
| Seed search by criteria | no | yes |
| Ore / vegetation | no <sup>4</sup> | no — [and why](#known-limitations) |
| Collaborative pins | **yes** | no |
| World-file upload | **yes**, full | seed only |
| Map image export | **yes** | no |

<sup>1</sup> `ReleaseProjectV97.data.unityweb` 6 395 404 B + `.wasm.code.unityweb`
6 578 642 B + `.wasm.framework.unityweb` 94 275 B.
<sup>2</sup> `"multithreading": false` in `Build/ReleaseProjectV97.json`.
<sup>3</sup> Measured: a warm reload draws all 65 visible tiles from storage with
zero worker renders.
<sup>4</sup> Its about page gives the reason: "too computationally expensive for
full-world calculation."

## Performance

Measured on an M5, seed `j3QV2ftr3y`.

**Rust, native, single core**

| | |
|---|---|
| World pregeneration (lakes, rivers, streams) | 156 ms |
| 256² biome tile | 16.2 ms |
| 256² terrain tile | 19.9 ms |
| 2048² patch texture for the 3D view | 718 ms |
| Full location placement → 12 006 sites | 6.86 s |

**In the browser, WebAssembly, 6 workers**

| | |
|---|---|
| Time to first map | ~2.1 s |
| World pregeneration, wall clock | 526 ms |
| Tile | 39–59 ms |
| Location placement | ~25 s, streamed — bosses and traders land in ~2 s |
| **Warm reload** | **0 tiles generated** |
| Seed search | ~30 seeds/s |
| Marker hit-test, 12 000 sites | 1.8 µs |
| Idle | 0 redraws, 0 busy workers |

Three things carry that, and two of them are about *not* doing work:

**Tiles are content-addressable.** A tile is a pure function of
`seed:mode:palette:z/x/y`, so one computed once is correct forever. They are
persisted to the Cache API and read back before a worker is ever asked, which
is why a revisit generates nothing. The store *gates* the worker request rather
than racing it — firing both would persist a tile and then regenerate it
anyway.

**Markers load per category.** A world holds ~12 000 sites and the default view
draws 58. Categories are fetched the first time they are switched on. Placement
itself still runs for all 183 types, because they compete for the same 64 m
zones and skipping one moves everything placed after it.

**The pool is deliberately not `cores - 1`.** Every worker generates terrain
from noise rather than fetching a baked tile, so a full pool means one pan
saturates the machine. At ~60% of cores, pregeneration is actually *faster*
(526 ms against 873 ms) because six workers contend less than nine.

## The Mac and iPhone app

One universal target builds for both. It is not the web app in a wrapper and it
is not the Rust generator behind an FFI shim: `apple/Sources/Worldgen/` is the
whole algorithm rewritten in Swift — Perlin, the Unity RNG, base height, the
per-biome height functions, rivers, the 183-entry location table, tile
rasterisation — 2 384 lines of Swift from 3 687 lines of Rust, ported line for
line under a stated
[porting contract](apple/Sources/Worldgen/UnityRandom.swift) that fixes how
each Rust construct maps (`wrapping_mul` → `&*`, `as u32` →
`UInt32(bitPattern:)`, every `f64 → f32` narrowing at the same point it
happens in Rust).

Linking the Rust crate would have been faster to write and worse to own: an
XCFramework, a cargo toolchain in every build, and a C boundary in the middle
of the one thing whose exactness the project rests on. The port is gated
against the original in CI instead — see [Accuracy](#the-swift-port-is-not-byte-identical).

The renderer is Metal rather than SwiftUI drawing: one textured quad per tile
over a quadtree LOD, instanced quads for markers, and glyph symbology
rasterised on the CPU from the same paths the web canvas draws.

- **Tiles are content-addressable here too**, and persisted — LZFSE over the
  raw pixel block rather than PNG, because PNG would mean a Core Graphics
  round-trip in both directions. **99 KB a tile** against 256 KB raw, and
  smaller than the web's PNGs. Measured: a warm launch draws all 56 visible
  tiles from disk with **zero** generation, in 60 ms against 270 ms cold.
- **The app reopens on the seed you left it on**, with that world's stored
  tiles read back into memory *before the first frame* — the reads overlap the
  world build instead of queueing behind it.
- **The stand-in for a tile that has not arrived is a cropped ancestor.** One
  sub-rect of the coarser tile that covers exactly this ground. Drawing the
  whole ancestor into a child's slot instead — which is what it did at first —
  puts a crushed copy of a 4x larger region in every slot, and reads on screen
  as the map violently refreshing at every zoom step. It measures as **4.8x
  further from ground truth** than the crop (`--lodshot` renders one viewport
  three ways and diffs the pixels).
- **LOD selection is just `round(zoom + log2(scale))` plus a dead band.**
  Holding the level through a gesture, which sounds like the way to stop
  re-tiling, lets tiles magnify by up to 3x before the level catches up; the
  snap back to sharp reads as refreshing just as much as a re-tile does.
- **The worker pool is P-cores plus half the E-cores.** Apple Silicon reports
  both in `activeProcessorCount` and they are not interchangeable for
  sustained work; 60% of everything yields 3 workers on a 4+6 part and leaves
  most of the machine idle.
- **One shared `WorldGenerator` across all workers.** It is immutable after
  pregeneration and carries the river grid — ~770 k points. A copy per worker
  cost 50 MB apiece and made every worker repeat the same 120 ms build.

Both of those last two came out of measuring rather than reading: the app sat
at 496 MB and 31% idle CPU, and neither cause was where it looked.

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

`MARKERS` toggles 15 categories — spawn, bosses, traders, crypts, camps, caves,
mines, fortresses, runestones, ruins, villages, wrecks, monuments, resources and
mysteries — drawn as flat geometric symbology rather than map-app pins, each
with a dark halo so it survives white mountains and pale ice. Hovering a marker
names it; boss, trader and spawn labels pin open once zoomed in. **12 006 sites
across 183 location types** for a typical seed.

Placement parameters are transcribed from Jötunn's auto-generated dump of a
running **Valheim 1.0.7**. Worth knowing when comparing against other sources:

- **`biome_area` is mostly Median, not Everything.** 67 of the 183 live types
  are Median-only, including every boss altar, the start temple and all three
  traders — so they never generate near a biome edge. An earlier version of
  this table had them as Everything, on the theory that the dump's "Edge
  Median" was a bitmask being misread. It *is* a bitmask, but plenty of types
  genuinely carry only the Median bit, and treating those as Everything moves
  boss and trader markers to places the game never puts them. On the default
  seed it moved Eikthyr's nearest altar from 1 806 m to 454 m.
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
web/
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
    core/store.ts           persistent tile store (Cache API)
    render/map.ts           pan/zoom, quadtree LOD, progressive refinement
apple/
  Sources/Worldgen/         the same algorithm in Swift — no Rust, no FFI
  Sources/Render/           Metal map: LOD, tile pool, disk store, glyph atlas
  Sources/App/              SwiftUI chrome, shared by macOS and iOS
  Shaders/Tile.metal        textured tile quads, instanced marker quads
  Tests/parity/             prints the same vectors the Rust harness does
scripts/parity.py           gates the two generators against each other
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
- **Seed hashing** — checked against two real `.fwl` world files as parsed by
  a third-party save tool. Those files store the phrase *and* the integer the
  game derived from it, so they are independent ground truth rather than
  another copy of our own assumption: `Kh0zDpuPnw → 810132289` and
  `q6GhJN6FwT → 517038747`, both exact.
- **Draw order** — `offset0..3`, `riverSeed`, `streamSeed`, **`offset4` last**.
  Easy to get wrong, silently produces a different world.

### The Swift port is not byte-identical

It is close, the gap is measured, and CI asserts the bound rather than
pretending it is zero — a gate that demanded byte equality would have to be
switched off, and a switched-off gate catches nothing.

Rust and Swift reach different `libm` implementations for `sin`, `cos` and
`pow`. Each is correctly rounded to within an ULP of the true result, but not
to the *same* ULP, and `GetBaseHeight` is deep enough that one ULP survives to
the output. Unity's `Mathf` semantics are reproduced on both sides (`Mathf.Sin`
is a double-precision `sin` narrowed to float, not a float `sinf`), which
removes the larger divergence; this is what is left.

`./scripts/parity.sh` runs both generators over seed `j3QV2ftr3y` and compares
68 vectors. **52 must match exactly**, and do:

- the RNG's internal state and its output vectors
- every seed-hash vector, including the two checked against real `.fwl` files
- the seed → offset draw order
- the Perlin checksum and the mirror-symmetry quirk
- which biome each probe position lands in
- every biome's share of world area
- **every boss, trader and start-temple position** — all 28 of them

**16 are bounded**, with these observed values:

| | divergence |
|---|---|
| Height in metres, 8 probes | 7 identical, one differs by **5.4e-5 m** |
| Raw height bit patterns | at worst **92 float32 steps** |
| Tile byte sums, 3 renders | **1-2** out of ~26 000 000 |
| Total locations placed | 12 163 vs 12 162 — **one site** |
| Per category | caves −1, ruins −2, villages +2 |

The location count is the only one a user could notice, and it is the expected
consequence rather than a separate bug: placement is sequential rejection
sampling against one shared occupancy map, so a single flipped constraint test
moves what comes after it. Spawn, boss and trader counts are unchanged, which
is what a seed report states.

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

## Known limitations

These are real and worth stating plainly.

1. **1.0 works, but its terrain is evidenced rather than byte-verified.**
   The terrain math is transcribed from decompiles of 0.218.15 and 0.221.4.
   **Valheim 1.0 did not bump the world-generation version** — it is still 2,
   so v2 *is* 1.0's ruleset. Two independent sources agree, both checked
   directly rather than taken on report:

   - valheim-map.world's live production code tags `1.0.7` as `WorldVer: 2`,
     the same value as every build back to Mistlands (Dec 2022), and its `.fwl`
     parser still treats `worldGenerationVersion == 2` as current.
   - `kirilloid/valheim`, a TypeScript reimplementation that mirrors the game's
     version constants, bumped `WORLD` 40 → 41, `PLAYER` 45 → 46 and
     `INVENTORY` 108 → 109 for 1.0 in one commit — and left `WORLD_GEN = 2`
     untouched.

   The 1.0 patch notes' only world-generation line is *"Optimized world
   generation to be much faster"*, filed under performance. And the location
   table matches a live 1.0.7 dump exactly. Nobody has published a 1.0
   decompile, so none of this is byte-level proof. Two specific things would
   be worth checking if a 1.0 dump ever appears:

   - **`GetBiomeHeight` gained a sixth parameter in 1.0.** Pre-1.0 it is
     `(biome, wx, wy, out Color mask, bool preGeneration = false)`; a mod fixed
     for 1.0 calls it with six arguments. What that parameter does, and whether
     it changes output at the default, is unknown.
   - **1.0 moved from Unity 2019 to Unity 6.** Everything here rests on
     `Mathf.PerlinNoise` being unchanged. It has been stable for a decade and
     our implementation matches 176 captured values, but those were captured
     from the older engine.

   Against that: the Deep North and Ashlands height functions are
   Harmony-patched by name and by IL transpiler in a world-generation mod whose
   1.0 fix did not touch those patches — good evidence their shape survived.

2. **Deep North terrain is the pre-1.0 shape, and probably correct.** Its ocean
   gap and biome placement come from the same verified path as everything else,
   and the evidence above says 1.0 layered content — locations, creatures, gear
   — over a band the generator already produced, rather than rewriting the
   height function. The one observable consequence here is that `DN_Bossroom`
   wants ground at 80 m altitude and finds none, so the Deep North boss does
   not place. That is pinned by a test rather than hidden.

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
cd web/crates/worldgen && cargo test --release   # 18 tests
./scripts/parity.sh                              # Rust generator vs Swift port
```

18 tests covering the Unity RNG and hash vectors, the 176-sample Perlin ground
truth, the mirror-symmetry quirk, seed→offset draw order, biome distribution
against independent community measurements, determinism, pole orientation,
world-edge falloff, and — for locations — that every type places at least one,
that placements respect their biome and distance constraints, and that no two
locations ever share a 64 m zone. One test renders a tile and asserts land
pixels are painted their own biome's colour, measured over *all* land rather
than region interiors, because an interiors-only check passes even with a
wildly over-wide boundary blend.

`scripts/parity.sh` builds both generators, runs them over the same seed and
gates the difference; see [above](#the-swift-port-is-not-byte-identical) for
what it holds exact and what it merely bounds.

CI runs four jobs on every push: the Rust suite, a web typecheck and build, a
Release build of the app for both macOS and iOS, and the parity gate.

Tagging `v*` builds and publishes the Mac app, universal and with the tag as
its version — the workflow reads both back out of the built bundle and refuses
to publish if either disagrees. Given five repository secrets —
`DEVELOPER_ID_CERT_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `APPLE_ID`,
`APPLE_ID_PASSWORD` and `APPLE_TEAM_ID` — it also signs with a Developer ID
certificate under the hardened runtime, notarises, staples the ticket and
checks the result against Gatekeeper. Without them it falls back to an ad-hoc signature,
so a fork still gets a working build.

Developed and checked against seed `j3QV2ftr3y`, the default in the UI and
`TEST_SEED` in the suite.

## Credits

- [valheim-map.world][vmw] by wd40bomber7 — came first, and is still the
  reference for what this kind of tool should do.
- [Jötunn](https://github.com/Valheim-Modding/Jotunn) — the auto-generated
  location and vegetation tables this transcribes, dumped from a running game.
- Iron Gate Studio, for Valheim.

Unofficial and unaffiliated. Not endorsed by Iron Gate.
