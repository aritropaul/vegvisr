import { TilePool } from './core/pool'
import { QueryWorker } from './core/query'
import { BIOME_NAMES, BIOME_ORDER, POI_KINDS, WATER_LEVEL, WORLD_EXTENT } from './core/protocol'
import type { Poi, SeedReport } from './core/protocol'
import { parseFwl } from './core/fwl'
import {
  decode as decodeUrl,
  defaultMarkers,
  write as writeUrl,
  type ViewState,
} from './core/urlstate'
import { MapView, glyph } from './render/map'
import { Terrain3D } from './render/terrain3d'
import { initAppLink } from './core/applink'

/**
 * World-generation rulesets Valheim has shipped, newest first.
 *
 * A world stores the version it was *created* under in its `.fwl` and keeps it
 * forever, so a seed only reproduces if you generate it under the same rules.
 * The differences are small but they move biome boundaries: v0 pushes
 * mountains 1500 m from spawn instead of 1000, and v0/v1 widen the marsh band
 * to 8000 m and raise the Mistlands noise threshold to 0.5.
 *
 * `VersionSetup` in the game only branches on `<= 0` and `<= 1`, so every
 * build from the Mistlands update onward behaves identically as far as terrain
 * is concerned — and 1.0 did **not** bump it. valheim-map.world's live code
 * tags 1.0.7 as world version 2, and kirilloid/valheim bumped every adjacent
 * save-format constant for 1.0 while leaving WORLD_GEN at 2. So there is no
 * separate 1.0 entry here because v2 *is* 1.0.
 */
const GEN_VERSIONS: Array<{ v: number; label: string; note?: string }> = [
  { v: 2, label: 'v2 · current', note: 'Mistlands (0.212.7, Dec 2022) through 1.0 — verified unchanged in 1.0.7' },
  { v: 1, label: 'v1 · pre-Mistlands', note: 'Wider marsh band, higher Mistlands threshold' },
  { v: 0, label: 'v0 · earliest', note: 'Mountains held 1500 m from spawn' },
]
const DEFAULT_GEN_VERSION = 2
let worldGenVersion = DEFAULT_GEN_VERSION

const $ = <T extends HTMLElement>(sel: string) => document.querySelector(sel) as T
const canvas = $<HTMLCanvasElement>('#map')
const seedInput = $<HTMLInputElement>('#seed')
const goBtn = $<HTMLButtonElement>('#go')
const bootEl = $<HTMLDivElement>('#boot')
const bootText = $<HTMLSpanElement>('#bootText')
const bootFill = $<HTMLElement>('#bootFill')

/** [classic, accessible] hex per biome ordinal, mirroring the Rust palettes. */
/** Mirrors the emissive ink table in the renderer. */
const SWATCH: Record<number, [string, string]> = {
  1: ['#a8e05f', '#c6f060'],
  4: ['#2f7d4f', '#289edc'],
  2: ['#9a7b45', '#f476ce'],
  3: ['#dce9f2', '#ffffff'],
  5: ['#d9b876', '#f6c43e'],
  9: ['#8a7bc8', '#b080ff'],
  6: ['#e0552f', '#ff8036'],
  7: ['#9fd8f0', '#7ee2ff'],
  8: ['#2654c4', '#3a68e2'],
}

/**
 * Viewport size in CSS pixels taken from the canvas backing store, not from
 * layout: the map canvas is display:none while the 3D view is active, so
 * getBoundingClientRect() would report 0x0 and collapse every world-bounds
 * calculation that depends on it.
 */
function viewportSize(): [number, number] {
  const dpr = window.devicePixelRatio || 1
  const c = document.querySelector('#map') as HTMLCanvasElement
  return [c.width / dpr, c.height / dpr]
}

const pool = new TilePool()
const queryWorker = new QueryWorker()
const view = new MapView(canvas, pool)

// Dev handles for inspecting pool/view state from the console.
Object.assign(window as unknown as Record<string, unknown>, { __pool: pool, __view: view })

// ── composition bars ──────────────────────────────────────────────────────
const barsEl = $<HTMLDivElement>('#bars')
barsEl.innerHTML = BIOME_ORDER.map(
  ([ord, name]) =>
    `<div class="bar" data-ord="${ord}"><span>${name}</span>` +
    `<div class="track"><i style="width:0%"></i></div><b>0.0</b></div>`,
).join('')

function paintBars(counts: Uint32Array, palette: number) {
  const total = BIOME_ORDER.reduce((a, [ord]) => a + (counts[ord] ?? 0), 0) || 1
  for (const [ord] of BIOME_ORDER) {
    const row = barsEl.querySelector<HTMLElement>(`[data-ord="${ord}"]`)!
    const pct = ((counts[ord] ?? 0) / total) * 100
    row.querySelector<HTMLElement>('i')!.style.width = `${pct.toFixed(1)}%`
    row.querySelector<HTMLElement>('i')!.style.background = SWATCH[ord][palette]
    row.querySelector<HTMLElement>('b')!.textContent = pct.toFixed(1)
  }
}

/// Bumped on every `generate()`; in-flight location passes for older seeds
/// check it before touching the view.
let generation = 0
const poiStatusEl = $<HTMLDivElement>('#poiStatus')

// ── seed report ───────────────────────────────────────────────────────────
const fmtKm2 = (v: number) => (v >= 10 ? v.toFixed(0) : v.toFixed(1))

function paintReport(r: SeedReport) {
  $('#repArea').textContent = `${fmtKm2(r.spawnAreaKm2)} km²`
  $('#repLargest').textContent = r.spawnIsLargest
    ? 'this one'
    : `${fmtKm2(r.largestKm2)} km²`
  $('#repCount').textContent = String(r.landmasses)
  $('#repReach').textContent = `${r.reachable}/${r.total} ON FOOT`
  $('#repSites').innerHTML = r.sites
    .slice()
    .sort((a, b) => Number(b.reachable) - Number(a.reachable) || a.dist - b.dist)
    .map(
      (s) =>
        `<button class="site-row ${s.reachable ? 'reach' : 'far'}" data-x="${s.x}" data-y="${s.y}">` +
        `<i>${s.reachable ? '✓' : '~'}</i><span>${s.label}</span><b>${fmtM(s.dist)}</b></button>`,
    )
    .join('')
  for (const row of $<HTMLDivElement>('#repSites').querySelectorAll<HTMLButtonElement>('.site-row')) {
    row.addEventListener('click', () => {
      view.centreOn(Number(row.dataset.x), Number(row.dataset.y))
    })
  }
}


// ── marker loading ────────────────────────────────────────────────────────
// Placement runs for all 183 location types no matter what — they compete for
// the same 64 m zones, so skipping one moves everything placed after it. What
// *is* skippable is shipping the result: a world holds ~12 000 sites and the
// default view shows 58. Categories are fetched the first time they are
// switched on, and the worker keeps the placement so later fetches are free.
const poisByKind = new Map<number, Poi[]>()
let poiLabelTable: Array<{ label: string; kind: number }> = []
let poiCounts: number[] = []

const kindMask = (kinds: Iterable<number>) => {
  let m = 0
  for (const k of kinds) m |= 1 << k
  return m
}

function rebuildPois(table = poiLabelTable) {
  const all: Poi[] = []
  for (const k of view.poiEnabled) {
    const list = poisByKind.get(k)
    if (list) all.push(...list)
  }
  view.setPois(all, table)
  paintPoiCounts()
}

async function ensureKindLoaded(kind: number) {
  // Already fetched: just put it back in the drawn set. Returning early
  // without rebuilding leaves the category switched on but invisible.
  if (poisByKind.has(kind)) {
    rebuildPois()
    return
  }
  const run = generation
  poiStatusEl.hidden = false
  poiStatusEl.textContent = `LOADING ${POI_KINDS[kind]?.name ?? 'MARKERS'}`
  try {
    const { pois, table } = await queryWorker.locations(1 << kind)
    if (run !== generation) return
    poiLabelTable = table
    poisByKind.set(kind, pois)
    rebuildPois(table)
  } finally {
    if (run === generation) poiStatusEl.hidden = true
  }
}

// ── marker toggles ────────────────────────────────────────────────────────
const poiListEl = $<HTMLDivElement>('#poiList')
poiListEl.innerHTML = POI_KINDS.map(
  (k) =>
    `<button class="poi${view.poiEnabled.has(k.id) ? ' on' : ''}" data-kind="${k.id}" ` +
    `style="--c:${k.color}"><span class="mk" style="color:${k.color}"></span>` +
    `${k.name}<b>0</b></button>`,
).join('')

for (const btn of poiListEl.querySelectorAll<HTMLButtonElement>('.poi')) {
  btn.addEventListener('click', () => {
    const kind = Number(btn.dataset.kind)
    const on = !btn.classList.contains('on')
    btn.classList.toggle('on', on)
    view.togglePoi(kind, on)
    if (on) void ensureKindLoaded(kind)
    else rebuildPois()
  })
}

function paintPoiCounts() {
  // Totals come from the worker so a category that has never been fetched
  // still shows how many sites it holds.
  const live = new Map<number, number>()
  for (const p of view.pois) live.set(p.kind, (live.get(p.kind) ?? 0) + 1)
  let total = 0
  for (const btn of poiListEl.querySelectorAll<HTMLButtonElement>('.poi')) {
    const kind = Number(btn.dataset.kind)
    const n = poiCounts[kind] ?? live.get(kind) ?? 0
    total += n
    btn.querySelector('b')!.textContent = String(n)
  }
  $('#poiTotal').textContent = String(total || view.pois.length)
}

// Hovering a marker surfaces its identity in telemetry.
const siteEl = $<HTMLDivElement>('#roSite')
view.onPoiHover = (p) => {
  if (!p) {
    siteEl.hidden = true
    return
  }
  const name = view.poiLabels[p.cfg]?.label ?? 'Location'
  const d = Math.round(Math.hypot(p.x, p.y)).toLocaleString()
  siteEl.hidden = false
  siteEl.textContent = `${name.toUpperCase()} · ${Math.round(p.x)}, ${Math.round(p.y)} · ${d} m`
}

// ── world locator ─────────────────────────────────────────────────────────
const locator = $<HTMLCanvasElement>('#locator')
function paintLocator() {
  const ctx = locator.getContext('2d')!
  const S = locator.width
  const R = S / 2 - 6
  ctx.clearRect(0, 0, S, S)
  const c = S / 2
  const mToPx = R / WORLD_EXTENT

  // Pole bands: Ashlands south, Deep North north.
  ctx.save()
  ctx.beginPath()
  ctx.arc(c, c, R, 0, Math.PI * 2)
  ctx.clip()
  ctx.fillStyle = 'rgba(255, 122, 82, 0.16)'
  ctx.fillRect(0, c + 6500 * mToPx, S, S)
  ctx.fillStyle = 'rgba(150, 216, 255, 0.14)'
  ctx.fillRect(0, 0, S, c - 6500 * mToPx)
  ctx.restore()

  ctx.strokeStyle = 'rgba(150, 235, 255, 0.4)'
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.arc(c, c, R, 0, Math.PI * 2)
  ctx.stroke()

  ctx.strokeStyle = 'rgba(150, 235, 255, 0.13)'
  ctx.beginPath()
  ctx.moveTo(c, c - R); ctx.lineTo(c, c + R)
  ctx.moveTo(c - R, c); ctx.lineTo(c + R, c)
  ctx.stroke()

  // Current viewport footprint.
  const [vw, vh] = viewportSize()
  const [wl, wt] = view.screenToWorld(0, 0)
  const [wr, wb] = view.screenToWorld(vw, vh)
  const x0 = c + wl * mToPx
  const y0 = c - wt * mToPx
  const w = (wr - wl) * mToPx
  const h = (wt - wb) * mToPx
  ctx.strokeStyle = '#e8c07a'
  ctx.lineWidth = 1
  if (w < 4 || h < 4) {
    ctx.beginPath()
    ctx.arc(x0 + w / 2, y0 + h / 2, 3.5, 0, Math.PI * 2)
    ctx.stroke()
  } else {
    // Clip so a viewport larger than the world doesn't draw off-panel.
    ctx.save()
    ctx.beginPath()
    ctx.rect(2, 2, S - 4, S - 4)
    ctx.clip()
    ctx.strokeRect(x0, y0, w, h)
    ctx.restore()
  }

  // Spawn.
  ctx.fillStyle = 'rgba(232, 192, 122, 0.95)'
  ctx.fillRect(c - 1.5, c - 1.5, 3, 3)
  $('#locSpan').textContent = `${fmtM(wr - wl)} × ${fmtM(wt - wb)}`
}

const fmtM = (m: number) => (m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m)} m`)

// ── telemetry ─────────────────────────────────────────────────────────────
view.onStats = (s) => {
  $('#tScale').textContent = `${s.mpp < 1 ? s.mpp.toFixed(2) : s.mpp.toFixed(1)} m/px`
  $('#tTiles').textContent = `${s.visibleTiles}v ${s.cachedTiles}c ${s.cacheMB.toFixed(0)}MB`
  $('#tLast').textContent = `${s.lastTileMs.toFixed(1)} ms${s.pending ? ` +${s.pending}` : ''}`
  $('#tWorkers').textContent = `${pool.size} · ${pool.pregenMs.toFixed(0)} ms`
  paintLocator()
  scheduleComposition()
}

// Recompute composition for the visible region once the view settles.
let compTimer = 0
function scheduleComposition() {
  clearTimeout(compTimer)
  compTimer = window.setTimeout(async () => {
    const [vw, vh] = viewportSize()
    const [wl, wt] = view.screenToWorld(0, 0)
    const [wr, wb] = view.screenToWorld(vw, vh)
    const spanX = wr - wl
    const spanY = wt - wb
    const counts = await queryWorker.histogram(wl, wt, spanX, spanY, 72)
    paintBars(counts, view.palette)
    $('#compScope').textContent =
      spanX >= WORLD_EXTENT * 2 && spanY >= WORLD_EXTENT * 2 ? 'WORLD' : fmtM(spanX).toUpperCase()
  }, 220)
}

// ── cursor readout ────────────────────────────────────────────────────────
let hoverBusy = false
let lastHover: [number, number] | null = null

/** Single readout path, shared by the 2D hover and the 3D raycast. */
function updateReadout(wx: number, wy: number) {
  lastHover = [wx, wy]
  if (hoverBusy) return
  hoverBusy = true
  void (async () => {
    while (lastHover) {
      const [x, y] = lastHover
      lastHover = null
      const r = await queryWorker.query(x, y)
      $('#roPos').textContent = `${Math.round(x)}, ${Math.round(y)}`
      $('#roBiome').textContent = BIOME_NAMES[r.biome] ?? '—'
      const alt = r.height - WATER_LEVEL
      $('#roAlt').textContent = `${alt >= 0 ? '+' : ''}${alt.toFixed(1)} m`
      $('#roDist').textContent = `${Math.round(Math.hypot(x, y)).toLocaleString()} m`
    }
    hoverBusy = false
  })()
}

view.onHover = updateReadout

// ── generate ──────────────────────────────────────────────────────────────
async function generate(seedName: string) {
  bootEl.classList.remove('hidden')
  bootFill.style.width = '12%'
  bootText.textContent = `BUILDING WORLD · ${pool.size + 1} WORKERS`
  goBtn.disabled = true

  const t0 = performance.now()
  pool.pregenMs = 0
  view.reset()
  bootFill.style.width = '46%'
  await Promise.all([
    pool.init(seedName, worldGenVersion),
    queryWorker.init(seedName, worldGenVersion),
  ])

  bootFill.style.width = '82%'
  bootText.textContent = 'PLACING LOCATIONS'
  $('#seedInt').textContent = String(pool.seed)
  view.invalidate()
  scheduleComposition()

  bootFill.style.width = '100%'
  bootText.textContent = `READY · ${(performance.now() - t0).toFixed(0)} MS`
  goBtn.disabled = false

  // Location placement is one pass over the whole world and costs seconds:
  // 183 location types, each rejection-sampling against the game's own attempt
  // caps. It used to be awaited here, which held the boot overlay — and the
  // map — hostage behind it. It is not needed to draw terrain, so it now lands
  // whenever it lands. `run` guards against a second seed overtaking the first.
  const run = ++generation
  poisByKind.clear()
  poiCounts = []
  poiStatusEl.hidden = false
  poiStatusEl.textContent = 'PLACING LOCATIONS · 0%'
  queryWorker.onLocationProgress = (progress, partial, table) => {
    if (run !== generation) return
    poiStatusEl.textContent = `PLACING LOCATIONS · ${Math.round(progress * 100)}%`
    // The first milestone carries every prioritised type — bosses, traders,
    // the start temple — so the useful markers appear seconds before the
    // long tail of ruins and monuments finishes.
    if (partial) {
      for (const k of view.poiEnabled) poisByKind.set(k, [])
      for (const p of partial) poisByKind.get(p.kind)?.push(p)
      rebuildPois(table ?? view.poiLabels)
    }
  }
  queryWorker
    .locations(kindMask(view.poiEnabled))
    .then(({ pois, table, report, counts }) => {
      // A newer seed has overtaken this one: drop the results, but do NOT
      // leave the banner up — the newer run owns it and will clear it itself.
      if (run !== generation) return
      poiLabelTable = table
      poiCounts = counts
      poisByKind.clear()
      for (const k of view.poiEnabled) poisByKind.set(k, [])
      for (const p of pois) poisByKind.get(p.kind)?.push(p)
      rebuildPois(table)
      paintReport(report)
      poiStatusEl.hidden = true
    })
    .catch((err) => {
      if (run !== generation) return
      poiStatusEl.textContent = 'LOCATION PASS FAILED'
      console.error(err)
    })

  syncUrl()
  setTimeout(() => bootEl.classList.add('hidden'), 260)
}


$('#gridBtn').addEventListener('click', (e) => {
  const btn = e.currentTarget as HTMLButtonElement
  view.showGrid = !view.showGrid
  btn.classList.toggle('active', view.showGrid)
  view.invalidate()
})
$('#fit').addEventListener('click', () => {
  view.fit()
  ;($('#fit') as HTMLButtonElement).classList.remove('active')
})
goBtn.addEventListener('click', () => void generate(seedInput.value.trim()))
seedInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') void generate(seedInput.value.trim())
})

// ── controls ──────────────────────────────────────────────────────────────
const wire = (sel: string, fn: (btn: HTMLButtonElement) => void) => {
  for (const btn of document.querySelectorAll<HTMLButtonElement>(sel)) {
    btn.addEventListener('click', () => {
      for (const b of document.querySelectorAll(sel)) b.classList.remove('active')
      btn.classList.add('active')
      fn(btn)
    })
  }
}

// ── 3D view ───────────────────────────────────────────────────────────────
const glCanvas = $<HTMLCanvasElement>('#gl')
const glOverlay = $<HTMLCanvasElement>('#glOverlay')
const mapCanvas = $<HTMLCanvasElement>('#map')
let terrain: Terrain3D | null = null
let is3D = false
let terrainToken = 0

/** Draws POI symbology on top of the 3D surface, projected through its MVP. */
function paintPoiOverlay() {
  if (!terrain) return
  const dpr = window.devicePixelRatio || 1
  const r = glOverlay.getBoundingClientRect()
  const w = Math.round(r.width * dpr)
  const h = Math.round(r.height * dpr)
  if (glOverlay.width !== w || glOverlay.height !== h) {
    glOverlay.width = w
    glOverlay.height = h
  }
  const ctx = glOverlay.getContext('2d')!
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  ctx.clearRect(0, 0, r.width, r.height)

  for (const p of view.pois) {
    if (!view.poiEnabled.has(p.kind)) continue
    const surface = poiHeight.get(p)
    // Outside the loaded patch: nothing to stand on, so don't draw it.
    if (surface === undefined) continue
    const hit = terrain.project(p.x, p.y, surface)
    if (!hit) continue
    const [sx, sy] = hit
    if (sx < -20 || sy < -20 || sx > r.width + 20 || sy > r.height + 20) continue
    const spec = POI_KINDS[p.kind]
    ctx.lineWidth = 3
    ctx.strokeStyle = 'rgba(2, 5, 11, 0.85)'
    glyph(ctx, spec.glyph, sx, sy, 5)
    ctx.stroke()
    ctx.lineWidth = 1.2
    ctx.strokeStyle = spec.color
    ctx.fillStyle = 'rgba(2, 5, 11, 0.55)'
    glyph(ctx, spec.glyph, sx, sy, 5)
    ctx.fill()
    ctx.stroke()
  }
}

/**
 * Terrain heights at marker positions, so symbols sit on the surface.
 * Membership doubles as the region cull: the 3D view loads one square patch,
 * and markers outside it would otherwise project onto empty space beyond the
 * slab edge.
 */
const poiHeight = new Map<(typeof view.pois)[number], number>()

/**
 * Loads the clipmap: a stack of square levels sharing one centre, the coarsest
 * covering the whole world and each finer one halving the span.
 *
 * The finest span is driven by how close the camera is, so flying down to
 * ground level pulls in metre-scale detail while the far horizon keeps the
 * world-spanning level it already has. Levels the camera has moved away from
 * are refetched; ones that still match are left alone.
 */
const LEVEL_GRID = 384
const LEVEL_TEX = 1024
/** Finest level we will ever ask for. Below this the worker cost stops buying
 *  visible detail, since the generator's own features are metres wide. */
const MIN_LEVEL_SPAN = 500

/** Where a level sits. */
interface LevelBox {
  span: number
  cx: number
  cy: number
}

interface LoadedLevel extends LevelBox {
  /** Kept so a level's hole can be re-punched when the finer level below it
   *  re-centres, without paying for another worker round trip. */
  heights: Float32Array
  grid: number
}
let loadedLevels: LoadedLevel[] = []

function levelPlan(centreX: number, centreY: number, finest: number): LevelBox[] {
  const plan: LevelBox[] = []
  const spans: number[] = []
  for (let sp = WORLD_EXTENT * 2; sp > finest * 1.5; sp /= 2) spans.push(sp)
  spans.push(Math.max(finest, MIN_LEVEL_SPAN))
  for (const span of spans) {
    if (span >= WORLD_EXTENT * 2) {
      // The world level stays pinned at the origin so it never swims.
      plan.push({ span, cx: 0, cy: 0 })
    } else {
      // Snap each level to its own cell size, otherwise the ring edges crawl
      // as the camera moves and the seams shimmer.
      const cell = (span / (LEVEL_GRID - 1)) * 2
      plan.push({
        span,
        cx: Math.round(centreX / cell) * cell,
        cy: Math.round(centreY / cell) * cell,
      })
    }
  }
  return plan
}

async function loadTerrain(region?: { cx: number; cy: number; span: number }) {
  if (!terrain) return
  const token = ++terrainToken

  let centreX: number
  let centreY: number
  let finest: number
  if (region) {
    centreX = region.cx
    centreY = region.cy
    finest = region.span
  } else {
    const [vw, vh] = viewportSize()
    const [wl, wt] = view.screenToWorld(0, 0)
    const [wr, wb] = view.screenToWorld(vw, vh)
    finest = Math.min(Math.max(wr - wl, wt - wb), WORLD_EXTENT * 2)
    centreX = (wl + wr) / 2
    centreY = (wt + wb) / 2
  }

  const plan = levelPlan(centreX, centreY, finest)
  const status = $('#surfStatus')
  status.hidden = false

  const moved: boolean[] = []
  for (let i = 0; i < plan.length; i++) {
    const want = plan[i]
    const have = loadedLevels[i]
    moved[i] = !(have && have.span === want.span && have.cx === want.cx && have.cy === want.cy)
  }

  const finerOf = (i: number) => plan[i + 1]
  const punch = (i: number, heights: Float32Array, grid: number) => {
    const want = plan[i]
    const finer = finerOf(i)
    // Punch the hole where the finer level actually sits, not at this level's
    // own centre — they snap to different grids and rarely coincide.
    terrain!.setLevel(
      i, heights, grid, want.span, want.cx, want.cy,
      finer?.cx ?? 0, finer?.cy ?? 0, finer ? finer.span / 2 : 0,
    )
  }

  for (let i = 0; i < plan.length; i++) {
    const want = plan[i]
    if (!moved[i]) continue
    status.textContent = `BUILDING SURFACE · ${i + 1}/${plan.length}`
    const ox = want.cx - want.span / 2
    const oy = want.cy + want.span / 2
    const res = await queryWorker.terrain(
      ox, oy, want.span, LEVEL_GRID, LEVEL_TEX, view.mode, view.palette,
    )
    if (token !== terrainToken) {
      res.bitmap.close()
      return
    }
    loadedLevels[i] = { ...want, heights: res.heights, grid: res.grid }
    punch(i, res.heights, res.grid)
    terrain.setLevelTexture(i, res.bitmap)
    terrain.invalidate()
  }

  // A level whose finer neighbour re-centred needs its hole moved even though
  // its own data is unchanged. Rebuild the mesh from the cached lattice.
  for (let i = 0; i < plan.length - 1; i++) {
    if (moved[i] || !moved[i + 1]) continue
    const have = loadedLevels[i]
    if (have) punch(i, have.heights, have.grid)
  }
  terrain.invalidate()
  terrain.trimLevels(plan.length)
  loadedLevels = loadedLevels.slice(0, plan.length)

  const fine = plan[plan.length - 1].span
  $('#surfSpan').textContent =
    fine >= 1000 ? `${(fine / 1000).toFixed(1)} km` : `${Math.round(fine)} m`

  // Marker heights come from the coarsest level, which always covers the whole
  // world — so no marker is culled just because it sits outside the fine ring.
  // Sampling the cached lattice avoids a second full-world render per reload.
  const base = loadedLevels[0]
  if (base && token === terrainToken) {
    const wox = base.cx - base.span / 2
    const woy = base.cy + base.span / 2
    const g = base.grid
    poiHeight.clear()
    for (const p of view.pois) {
      const i = Math.round(((p.x - wox) / base.span) * (g - 1))
      const j = Math.round(((woy - p.y) / base.span) * (g - 1))
      if (i >= 0 && j >= 0 && i < g && j < g) poiHeight.set(p, base.heights[j * g + i])
    }
  }
  if (token === terrainToken) status.hidden = true
}

function setView3D(on: boolean) {
  if (on === is3D) return
  is3D = on
  mapCanvas.hidden = on
  glCanvas.hidden = !on
  glOverlay.hidden = !on
  $('#hint3d').hidden = !on
  if (terrain) terrain.enabled = on
  if (on) {
    let created = false
    if (!terrain) {
      created = true
      try {
        terrain = new Terrain3D(glCanvas)
        terrain.onFrame = paintPoiOverlay
        terrain.enabled = true
        // Re-centre the finer clipmap levels as the camera zooms or flies.
        // The world-spanning level is pinned, so this never removes terrain.
        terrain.onNeedDetail = (cx, cy, span) => void loadTerrain({ cx, cy, span })
        // Telemetry in 3D comes from raycasting the height field.
        terrain.onPick = (wx, wy) => updateReadout(wx, wy)
      } catch (err) {
        console.error('[3d] unavailable', err)
        bootText.textContent = 'WEBGL2 UNAVAILABLE'
        is3D = false
        mapCanvas.hidden = false
        glCanvas.hidden = true
        glOverlay.hidden = true
        $('#hint3d').hidden = true
        return
      }
    }
    // Frame the world every time the 3D view is opened. The camera object
    // persists across toggles, so a dolly left at its minimum would otherwise
    // reopen with the eye inside the surface and nothing on screen.
    if (created || loadedLevels.length === 0) terrain.frameWorld()
    void loadTerrain()
  } else {
    view.invalidate()
  }
}

wire('[data-view]', (b) => setView3D(b.dataset.view === '3d'))

wire('[data-mode]', (b) => {
  view.setMode(Number(b.dataset.mode))
  if (is3D) void loadTerrain()
})
wire('[data-palette]', (b) => {
  const p = Number(b.dataset.palette)
  view.setPalette(p)
  scheduleComposition()
  if (is3D) void loadTerrain()
})

;(window as unknown as Record<string, unknown>).__map = { pool, view, queryWorker, get t3d() { return terrain } }


// ── find ──────────────────────────────────────────────────────────────────
const findEl = $<HTMLInputElement>('#find')
const findListEl = $<HTMLDivElement>('#findList')

/** `1234, -567` / `1234 -567` / `-1.2k 3.4k` — anything that reads as a pair. */
function parseCoords(q: string): [number, number] | null {
  const m = q.trim().match(/^(-?[\d.]+)\s*k?\s*[, ]\s*(-?[\d.]+)\s*k?$/i)
  if (!m) return null
  const scale = (t: string) => (/k$/i.test(t) ? 1000 : 1)
  const parts = q.trim().split(/[, ]+/)
  const x = Number(m[1]) * scale(parts[0])
  const y = Number(m[2]) * scale(parts[1] ?? '')
  return Number.isFinite(x) && Number.isFinite(y) ? [x, y] : null
}

function runFind(q: string) {
  q = q.trim()
  if (!q) {
    findListEl.innerHTML = ''
    return
  }
  const coord = parseCoords(q)
  if (coord) {
    findListEl.innerHTML =
      `<button class="find-row" data-x="${coord[0]}" data-y="${coord[1]}">` +
      `<span>GO TO ${Math.round(coord[0])}, ${Math.round(coord[1])}</span><b></b><em></em></button>`
    bindFindRows()
    return
  }
  const needle = q.toLowerCase()
  // Rank by name match, then by distance from the current view centre — the
  // nearest Burial Chamber is almost always the one being looked for.
  const hits = view.pois
    .map((p) => ({ p, label: view.poiLabels[p.cfg]?.label ?? '' }))
    .filter((h) => h.label.toLowerCase().includes(needle))
    .map((h) => ({ ...h, d: Math.hypot(h.p.x - view.cx, h.p.y - view.cy) }))
    .sort((a, b) => a.d - b.d)
    .slice(0, 12)

  findListEl.innerHTML = hits.length
    ? hits
        .map(
          (h) =>
            `<button class="find-row" data-x="${h.p.x}" data-y="${h.p.y}">` +
            `<span>${h.label}</span>` +
            `<i>${h.p.reachable ? '\u2713' : ''}</i>` +
            `<b>${fmtM(Math.hypot(h.p.x, h.p.y))}</b></button>`,
        )
        .join('')
    : `<div class="find-row"><span>NO MATCH</span><b></b><em></em></div>`
  bindFindRows()
}

function bindFindRows() {
  for (const row of findListEl.querySelectorAll<HTMLButtonElement>('.find-row[data-x]')) {
    row.addEventListener('click', () => {
      view.centreOn(Number(row.dataset.x), Number(row.dataset.y))
      findListEl.innerHTML = ''
      findEl.blur()
    })
  }
}

let findTimer = 0
findEl.addEventListener('input', () => {
  clearTimeout(findTimer)
  findTimer = window.setTimeout(() => runFind(findEl.value), 110)
})
findEl.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    findEl.value = ''
    findListEl.innerHTML = ''
    findEl.blur()
  }
  if (e.key === 'Enter') {
    const first = findListEl.querySelector<HTMLButtonElement>('.find-row[data-x]')
    first?.click()
  }
})

// ── ruler ─────────────────────────────────────────────────────────────────
const rulerBtn = $<HTMLButtonElement>('#rulerBtn')
// The ruler gets its own telemetry row: RANGE is rewritten on every pointer
// move by updateReadout, so sharing it would blank the measurement instantly.
const roRuler = $<HTMLElement>('#roRuler')
const roRulerK = $<HTMLElement>('#roRulerK')
let rulerOn = false

function setRuler(on: boolean) {
  rulerOn = on
  rulerBtn.classList.toggle('active', on)
  canvas.style.cursor = on ? 'crosshair' : ''
  roRuler.hidden = !on
  roRulerK.hidden = !on
  if (on) {
    view.startMeasure()
    roRuler.textContent = 'CLICK TO ADD POINTS'
  } else {
    view.endMeasure()
  }
}
rulerBtn.addEventListener('click', () => setRuler(!rulerOn))

view.onMeasure = (total, bearing, leg) => {
  if (!rulerOn || total === 0) return
  roRuler.textContent =
    `${fmtM(total)}${bearing === null ? '' : `  ${Math.round(bearing)}\u00b0`}` +
    (leg !== total ? `  (leg ${fmtM(leg)})` : '')
}

// ── share ─────────────────────────────────────────────────────────────────
const shareBtn = $<HTMLButtonElement>('#shareBtn')
shareBtn.addEventListener('click', async () => {
  syncUrlNow()
  try {
    await navigator.clipboard.writeText(location.href)
    shareBtn.textContent = 'COPIED'
  } catch {
    // Clipboard can be refused (permissions, insecure context). The address
    // bar is already correct, so say so rather than failing silently.
    shareBtn.textContent = 'IN URL BAR'
  }
  setTimeout(() => (shareBtn.textContent = 'SHARE'), 1400)
})

window.addEventListener('keydown', (e) => {
  const typing = document.activeElement === findEl || document.activeElement === seedInput
  if (e.key === 'Escape' && rulerOn) {
    setRuler(false)
    return
  }
  if (typing) return
  if (e.key === '/' || e.key === 'f') {
    e.preventDefault()
    findEl.focus()
  }
  if (e.key === 'm') setRuler(!rulerOn)
})


// ── world-file drop ───────────────────────────────────────────────────────
// Dropping a .fwl sidesteps the single most common cause of "this map doesn't
// match my game": a mistyped seed. It also carries the world-generation
// version the world was created under, which a typed seed cannot.
const dropHint = $<HTMLDivElement>('#dropHint')

// `dragleave` is unreliable — it fires for every child boundary and is skipped
// entirely if a drag ends outside the window — so the hint is also on a
// watchdog that clears it shortly after the last dragover.
let dropTimer = 0
function showDrop(on: boolean) {
  dropHint.hidden = !on
  clearTimeout(dropTimer)
  if (on) dropTimer = window.setTimeout(() => (dropHint.hidden = true), 400)
}

window.addEventListener('dragover', (e) => {
  // Only react to an actual file drag, not text selections.
  if (!e.dataTransfer?.types.includes('Files')) return
  e.preventDefault()
  showDrop(true)
})
window.addEventListener('dragleave', () => showDrop(false))
window.addEventListener('dragend', () => showDrop(false))
window.addEventListener('drop', async (e) => {
  e.preventDefault()
  showDrop(false)
  const file = e.dataTransfer?.files?.[0]
  if (!file) return
  if (!/\.fwl(\.old|2)?$/i.test(file.name)) {
    bootText.textContent = 'NOT A .FWL WORLD FILE'
    return
  }
  try {
    const w = parseFwl(await file.arrayBuffer())
    seedInput.value = w.seedName
    // Generate under the rules the world was actually created with, rather
    // than rendering the default and hoping they match. This is the whole
    // reason the file is worth reading beyond the seed.
    const known = GEN_VERSIONS.some((g) => g.v === w.worldGenVersion)
    setGenVersion(known ? w.worldGenVersion : DEFAULT_GEN_VERSION)
    const warn = $<HTMLElement>('#genWarn')
    warn.hidden = known
    if (!known) {
      warn.textContent = `WORLD v${w.worldGenVersion}`
      warn.title =
        `"${w.name}" records worldGenVersion ${w.worldGenVersion}, which this ` +
        `tool does not implement. Generated as v${DEFAULT_GEN_VERSION} instead; ` +
        `terrain may differ.`
    }
    await generate(w.seedName)
    bootText.textContent = `LOADED ${w.name}`
  } catch (err) {
    bootText.textContent = 'COULD NOT READ THAT WORLD FILE'
    console.error(err)
  }
})



// ── world-generation version ──────────────────────────────────────────────
const genVerEl = $<HTMLSelectElement>('#genVer')
genVerEl.innerHTML = GEN_VERSIONS.map(
  (g) => `<option value="${g.v}" title="${g.note ?? ''}">${g.label}</option>`,
).join('')

function setGenVersion(v: number) {
  worldGenVersion = v
  genVerEl.value = String(v)
}

genVerEl.addEventListener('change', () => {
  setGenVersion(Number(genVerEl.value))
  $<HTMLElement>('#genWarn').hidden = true
  syncUrl()
  void generate(seedInput.value.trim())
})

// ── seed search ───────────────────────────────────────────────────────────
// Biomes people actually plan a start around. Ashlands and Deep North are
// omitted: both are polar bands that no starting landmass ever reaches, so
// offering them would only ever produce an empty search.
// `bit` is the Heightmap.Biome flag the generator uses; `ord` indexes SWATCH,
// which is ordered for the composition chart rather than by flag value.
const SEARCHABLE: Array<{ name: string; bit: number; ord: number }> = [
  { name: 'MEADOWS', bit: 1, ord: 1 },
  { name: 'BLACK FOREST', bit: 8, ord: 4 },
  { name: 'SWAMP', bit: 2, ord: 2 },
  { name: 'MOUNTAIN', bit: 4, ord: 3 },
  { name: 'PLAINS', bit: 16, ord: 5 },
  { name: 'MISTLANDS', bit: 512, ord: 9 },
]

const biomePickEl = $<HTMLDivElement>('#biomePick')
const searchHitsEl = $<HTMLDivElement>('#searchHits')
const searchBtn = $<HTMLButtonElement>('#searchBtn')
const findStat = $<HTMLElement>('#findStat')
const minArea = $<HTMLInputElement>('#minArea')
const minAreaVal = $<HTMLElement>('#minAreaVal')
const wanted = new Set<number>([1, 8, 2])

biomePickEl.innerHTML = SEARCHABLE.map(
  (b) =>
    `<button class="bchip" data-bit="${b.bit}" data-ord="${b.ord}">${b.name}</button>`,
).join('')

function paintChips() {
  for (const b of biomePickEl.querySelectorAll<HTMLButtonElement>('.bchip')) {
    const bit = Number(b.dataset.bit)
    const on = wanted.has(bit)
    b.classList.toggle('on', on)
    b.style.background = on
      ? (SWATCH[Number(b.dataset.ord)]?.[view.palette] ?? '#ffd77a')
      : 'transparent'
  }
}
for (const b of biomePickEl.querySelectorAll<HTMLButtonElement>('.bchip')) {
  b.addEventListener('click', () => {
    const bit = Number(b.dataset.bit)
    if (wanted.has(bit)) wanted.delete(bit)
    else wanted.add(bit)
    paintChips()
  })
}
paintChips()

minArea.addEventListener('input', () => {
  minAreaVal.textContent = `${minArea.value} km²`
})

let searchStart = 0
function setSearching(on: boolean) {
  searchBtn.classList.toggle('active', on)
  searchBtn.textContent = on ? 'STOP' : 'SEARCH'
  if (!on) {
    pool.stopSearch()
    return
  }
  searchHitsEl.innerHTML = ''
  searchStart = performance.now()
  let mask = 0
  for (const bit of wanted) mask |= bit
  pool.startSearch(
    {
      // The cheap pre-filter asks the same question over a disc around spawn.
      // It is a necessary condition for the landmass test and costs ~1 ms
      // against ~125 ms, so it pays for itself many times over.
      radius: 4000,
      nearMask: mask,
      minHomeKm2: Number(minArea.value),
      homeMask: mask,
    },
    (hits, scanned) => {
      const rate = scanned / ((performance.now() - searchStart) / 1000)
      findStat.textContent = `${scanned} SCANNED · ${rate.toFixed(0)}/S`
      // The pool stops itself after a time budget; keep the button honest.
      if (!pool.searching) {
        searchBtn.classList.remove('active')
        searchBtn.textContent = 'SEARCH'
        findStat.textContent = `${scanned} SCANNED · STOPPED`
      }
      for (const h of hits) {
        const row = document.createElement('button')
        row.className = 'hit-row'
        row.innerHTML = `<span>${h.phrase}</span><b>${h.homeKm2.toFixed(1)} km²</b>`
        row.addEventListener('click', () => {
          seedInput.value = h.phrase
          setSearching(false)
          void generate(h.phrase)
        })
        searchHitsEl.prepend(row)
      }
      while (searchHitsEl.childElementCount > 40) searchHitsEl.lastElementChild?.remove()
    },
  )
}
searchBtn.addEventListener('click', () => setSearching(!pool.searching))

// ── address-bar state ─────────────────────────────────────────────────────
let urlTimer = 0
function syncUrlNow() {
  clearTimeout(urlTimer)
  let markers = 0
  for (const k of view.poiEnabled) markers |= 1 << k
  writeUrl({
    seed: seedInput.value.trim(),
    cx: view.cx,
    cy: view.cy,
    zoom: view.zoom,
    mode: view.mode,
    palette: view.palette,
    three: is3D,
    grid: view.showGrid,
    markers,
    gen: worldGenVersion,
  })
}

function syncUrl() {
  clearTimeout(urlTimer)
  // Coalesce: panning fires this on every frame.
  urlTimer = window.setTimeout(syncUrlNow, 220)
}
view.onViewChange = syncUrl

function applyState(st: ViewState) {
  if (st.mode) {
    view.setMode(st.mode)
    for (const b of document.querySelectorAll<HTMLButtonElement>('[data-mode]')) {
      b.classList.toggle('active', Number(b.dataset.mode) === st.mode)
    }
  }
  if (st.palette) {
    view.setPalette(st.palette)
    for (const b of document.querySelectorAll<HTMLButtonElement>('[data-palette]')) {
      b.classList.toggle('active', Number(b.dataset.palette) === st.palette)
    }
  }
  if (!st.grid) {
    view.showGrid = false
    $('#gridBtn').classList.remove('active')
  }
  if (st.markers !== defaultMarkers()) {
    for (const k of POI_KINDS) view.togglePoi(k.id, (st.markers & (1 << k.id)) !== 0)
    for (const btn of poiListEl.querySelectorAll<HTMLButtonElement>('.poi')) {
      btn.classList.toggle('on', view.poiEnabled.has(Number(btn.dataset.kind)))
    }
  }
  if (st.cx || st.cy || st.zoom) {
    view.cx = st.cx
    view.cy = st.cy
    if (st.zoom) view.zoom = st.zoom
    view.invalidate()
  }
}

initAppLink()

const boot = decodeUrl(location.search, seedInput.value.trim())
seedInput.value = boot.seed
setGenVersion(GEN_VERSIONS.some((g) => g.v === boot.gen) ? boot.gen : DEFAULT_GEN_VERSION)
view.fit()
applyState(boot)
void generate(boot.seed).then(() => {
  if (boot.three) {
    for (const b of document.querySelectorAll<HTMLButtonElement>('[data-view]')) {
      b.classList.toggle('active', b.dataset.view === '3d')
    }
    setView3D(true)
  }
})
