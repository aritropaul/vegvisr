import { TileCache } from '../core/cache'
import { TilePool } from '../core/pool'
import {
  MAX_ZOOM,
  POI_KINDS,
  TILE_SIZE,
  WORLD_EXTENT,
  WORLD_SPAN,
  metersPerPixel,
  tileSpan,
  type Poi,
} from '../core/protocol'

const clamp = (v: number, lo: number, hi: number) => (v < lo ? lo : v > hi ? hi : v)

/** Cache key. The seed is part of it on purpose: `reset()` clears the cache on
 *  every seed change, but keying by seed means a stale tile cannot be served
 *  even if that ever stops happening. Tiles are the one thing here where being
 *  wrong is silent — a mismatched tile just looks like terrain. */
const keyOf = (
  seed: number,
  mode: number,
  palette: number,
  z: number,
  x: number,
  y: number,
) => `${seed}:${mode}:${palette}:${z}/${x}/${y}`

/** Snap to a 1/2/5 x 10^n ladder so grid lines land on round coordinates. */
function niceStep(target: number): number {
  const mag = 10 ** Math.floor(Math.log10(Math.max(target, 1)))
  const norm = target / mag
  const snapped = norm < 1.5 ? 1 : norm < 3.5 ? 2 : norm < 7.5 ? 5 : 10
  return snapped * mag
}

/** Instrument symbology: one distinct silhouette per POI category. */
export function glyph(ctx: CanvasRenderingContext2D, kind: string, x: number, y: number, r: number) {
  ctx.beginPath()
  switch (kind) {
    case 'diamond':
      ctx.moveTo(x, y - r); ctx.lineTo(x + r, y); ctx.lineTo(x, y + r); ctx.lineTo(x - r, y)
      ctx.closePath()
      break
    case 'triangle':
      ctx.moveTo(x, y - r); ctx.lineTo(x + r * 0.92, y + r * 0.72)
      ctx.lineTo(x - r * 0.92, y + r * 0.72)
      ctx.closePath()
      break
    case 'square':
      ctx.rect(x - r * 0.78, y - r * 0.78, r * 1.56, r * 1.56)
      break
    case 'hex': {
      for (let i = 0; i < 6; i++) {
        const a = (Math.PI / 3) * i - Math.PI / 2
        const xx = x + Math.cos(a) * r
        const yy = y + Math.sin(a) * r
        i === 0 ? ctx.moveTo(xx, yy) : ctx.lineTo(xx, yy)
      }
      ctx.closePath()
      break
    }
    case 'arch':
      ctx.moveTo(x - r * 0.85, y + r * 0.7)
      ctx.lineTo(x - r * 0.85, y)
      ctx.arc(x, y, r * 0.85, Math.PI, 0)
      ctx.lineTo(x + r * 0.85, y + r * 0.7)
      ctx.closePath()
      break
    case 'keep':
      ctx.moveTo(x - r, y + r * 0.8); ctx.lineTo(x - r, y - r * 0.35)
      ctx.lineTo(x - r * 0.45, y - r * 0.35); ctx.lineTo(x - r * 0.45, y - r)
      ctx.lineTo(x + r * 0.45, y - r); ctx.lineTo(x + r * 0.45, y - r * 0.35)
      ctx.lineTo(x + r, y - r * 0.35); ctx.lineTo(x + r, y + r * 0.8)
      ctx.closePath()
      break
    case 'coin':
      ctx.arc(x, y, r * 0.88, 0, Math.PI * 2)
      ctx.closePath()
      ctx.moveTo(x + r * 0.3, y)
      ctx.arc(x, y, r * 0.3, 0, Math.PI * 2)
      break
    case 'rune':
      // Standing stone: a menhir with a rounded top.
      ctx.moveTo(x - r * 0.6, y + r)
      ctx.lineTo(x - r * 0.6, y - r * 0.3)
      ctx.arc(x, y - r * 0.3, r * 0.6, Math.PI, 0)
      ctx.lineTo(x + r * 0.6, y + r)
      ctx.closePath()
      break
    case 'ruin':
      // Two broken columns of unequal height.
      ctx.rect(x - r * 0.85, y - r * 0.2, r * 0.5, r * 1.2)
      ctx.rect(x + r * 0.2, y - r * 0.9, r * 0.5, r * 1.9)
      break
    case 'house':
      ctx.moveTo(x, y - r)
      ctx.lineTo(x + r * 0.9, y - r * 0.1)
      ctx.lineTo(x + r * 0.9, y + r * 0.85)
      ctx.lineTo(x - r * 0.9, y + r * 0.85)
      ctx.lineTo(x - r * 0.9, y - r * 0.1)
      ctx.closePath()
      break
    case 'hull':
      // Boat hull: a shallow crescent with a mast.
      ctx.moveTo(x - r, y - r * 0.1)
      ctx.quadraticCurveTo(x, y + r * 0.95, x + r, y - r * 0.1)
      ctx.closePath()
      ctx.moveTo(x, y - r * 0.15)
      ctx.lineTo(x, y - r)
      break
    case 'menhir':
      ctx.moveTo(x, y - r)
      ctx.lineTo(x + r * 0.45, y + r)
      ctx.lineTo(x - r * 0.45, y + r)
      ctx.closePath()
      ctx.moveTo(x - r * 0.8, y + r)
      ctx.lineTo(x + r * 0.8, y + r)
      break
    case 'node':
      // Six-spoke asterisk — reads as a deposit without a fill.
      for (let i = 0; i < 3; i++) {
        const a = (Math.PI / 3) * i
        ctx.moveTo(x - Math.cos(a) * r, y - Math.sin(a) * r)
        ctx.lineTo(x + Math.cos(a) * r, y + Math.sin(a) * r)
      }
      break
    case 'sigil':
      ctx.arc(x, y, r * 0.9, 0, Math.PI * 2)
      ctx.moveTo(x + r * 0.22, y)
      ctx.arc(x, y, r * 0.22, 0, Math.PI * 2)
      break
    case 'spawn':
    default:
      ctx.arc(x, y, r * 0.7, 0, Math.PI * 2)
      ctx.moveTo(x - r * 1.5, y); ctx.lineTo(x - r * 0.9, y)
      ctx.moveTo(x + r * 0.9, y); ctx.lineTo(x + r * 1.5, y)
      ctx.moveTo(x, y - r * 1.5); ctx.lineTo(x, y - r * 0.9)
      ctx.moveTo(x, y + r * 0.9); ctx.lineTo(x, y + r * 1.5)
      break
  }
}

const fmtCoord = (v: number) =>
  Math.abs(v) >= 1000 ? `${(v / 1000).toFixed(v % 1000 === 0 ? 0 : 1)}k` : `${Math.round(v)}`

export interface Stats {
  visibleTiles: number
  cachedTiles: number
  cacheMB: number
  lastTileMs: number
  pending: number
  mpp: number
}

export class MapView {
  private ctx: CanvasRenderingContext2D
  private cache = new TileCache()
  private dirty = true
  private raf = 0
  private dpr = 1

  /** View centre in world units. */
  cx = 0
  cy = 0
  /** Continuous zoom; integer steps double the resolution. */
  zoom = 0
  mode = 0
  palette = 0
  /** Fired whenever anything a permalink encodes changes. */
  onViewChange?: () => void

  /**
   * Ruler. `pts` are committed vertices in world space; the segment from the
   * last vertex to the cursor is live. Kept here rather than in main.ts
   * because it needs the same world/screen transform the map draws with.
   */
  measure: { pts: Array<[number, number]> } | null = null
  onMeasure?: (totalM: number, bearingDeg: number | null, legM: number) => void

  private vx = 0
  private vy = 0
  private dragging = false
  private lastPointer: [number, number] | null = null
  private lastMoveTime = 0
  private generation = 0
  /** Keys with an outstanding request, so frames don't re-issue them. */
  private requested = new Set<string>()
  /** Cursor position in CSS pixels, for the crosshair. */
  cursor: [number, number] | null = null
  showGrid = true

  /** Placed points of interest, and which categories are visible. */
  pois: Poi[] = []
  poiLabels: Array<{ label: string; kind: number }> = []
  poiEnabled = new Set<number>(POI_KINDS.filter((k) => k.defaultOn).map((k) => k.id))
  hoveredPoi: Poi | null = null
  onPoiHover?: (p: Poi | null) => void

  stats: Stats = {
    visibleTiles: 0,
    cachedTiles: 0,
    cacheMB: 0,
    lastTileMs: 0,
    pending: 0,
    mpp: 0,
  }
  onStats?: (s: Stats) => void
  onHover?: (wx: number, wy: number) => void

  constructor(
    private canvas: HTMLCanvasElement,
    private pool: TilePool,
  ) {
    const ctx = canvas.getContext('2d', { alpha: false })
    if (!ctx) throw new Error('2d context unavailable')
    this.ctx = ctx
    pool.setTileMsHook((ms) => {
      this.stats.lastTileMs = ms
    })
    this.resize()
    window.addEventListener('resize', () => this.resize())
    this.bindInput()
    this.loop()
  }

  /** Pixels per world unit at the current zoom. */
  private get scale() {
    return (TILE_SIZE * 2 ** this.zoom) / WORLD_SPAN
  }

  private resize() {
    this.dpr = window.devicePixelRatio || 1
    const r = this.canvas.getBoundingClientRect()
    this.canvas.width = Math.round(r.width * this.dpr)
    this.canvas.height = Math.round(r.height * this.dpr)
    this.invalidate()
  }

  /** Fit the whole world to the viewport. */
  /** Centre the view on a world position, zooming in if currently zoomed out
   *  far enough that the target would be a single pixel. Used by the seed
   *  report to jump to a boss or trader. */
  centreOn(wx: number, wy: number, minZoom = 3) {
    this.cx = wx
    this.cy = wy
    if (this.zoom < minZoom) this.zoom = minZoom
    this.clampCentre()
    this.invalidate()
    this.onViewChange?.()
  }

  fit() {
    const w = this.canvas.width / this.dpr
    const h = this.canvas.height / this.dpr
    const s = Math.min(w, h) / WORLD_SPAN
    this.zoom = Math.log2((s * WORLD_SPAN) / TILE_SIZE)
    this.cx = 0
    this.cy = 0
    this.invalidate()
  }

  reset() {
    this.cache.clear()
    this.requested.clear()
    this.generation++
    this.invalidate()
  }

  /** Previous mode/palette, used as an instant placeholder while re-rendering. */
  private prevVariant: [number, number] | null = null

  setMode(m: number) {
    if (m !== this.mode) this.onViewChange?.()
    if (m === this.mode) return
    // Tiles are namespaced by mode in the cache key, so the old ones stay
    // valid — keeping them makes toggling back instant.
    this.prevVariant = [this.mode, this.palette]
    this.mode = m
    this.invalidate()
  }

  setPalette(p: number) {
    if (p === this.palette) return
    this.onViewChange?.()
    this.prevVariant = [this.mode, this.palette]
    this.palette = p
    this.invalidate()
  }

  invalidate() {
    this.dirty = true
  }

  /** Inverse of `screenToWorld`; CSS pixels, not device pixels. */
  worldToScreen(wx: number, wy: number): [number, number] {
    const w = this.canvas.width / this.dpr
    const h = this.canvas.height / this.dpr
    return [w / 2 + (wx - this.cx) * this.scale, h / 2 - (wy - this.cy) * this.scale]
  }

  screenToWorld(sx: number, sy: number): [number, number] {
    const w = this.canvas.width / this.dpr
    const h = this.canvas.height / this.dpr
    // World north is up, screen Y is down.
    return [this.cx + (sx - w / 2) / this.scale, this.cy - (sy - h / 2) / this.scale]
  }

  private bindInput() {
    const el = this.canvas

    el.addEventListener('pointerdown', (e) => {
      if (this.measure && e.button === 0) {
        const r = el.getBoundingClientRect()
        this.measure.pts.push(this.screenToWorld(e.clientX - r.left, e.clientY - r.top))
        this.invalidate()
        return
      }
      el.setPointerCapture(e.pointerId)
      this.dragging = true
      this.lastPointer = [e.clientX, e.clientY]
      this.vx = this.vy = 0
    })

    el.addEventListener('pointermove', (e) => {
      const r = el.getBoundingClientRect()
      const sx = e.clientX - r.left
      const sy = e.clientY - r.top
      this.cursor = [sx, sy]
      const [wx, wy] = this.screenToWorld(sx, sy)
      const hit = this.hitTestPoi(sx, sy)
      if (hit !== this.hoveredPoi) {
        this.hoveredPoi = hit
        this.onPoiHover?.(hit)
      }
      this.invalidate()
      this.onHover?.(wx, wy)
      if (this.measure) {
        const st = this.measureStats()
        this.onMeasure?.(st.total, st.bearing, st.leg)
      }
      if (!this.dragging || !this.lastPointer) return
      const dx = e.clientX - this.lastPointer[0]
      const dy = e.clientY - this.lastPointer[1]
      this.lastPointer = [e.clientX, e.clientY]
      const now = performance.now()
      const dt = Math.max(1, now - this.lastMoveTime)
      this.lastMoveTime = now
      this.vx = dx / dt
      this.vy = dy / dt
      this.cx -= dx / this.scale
      this.cy += dy / this.scale
      this.clampCentre()
      this.invalidate()
    })

    const end = () => {
      if (!this.dragging) return
      this.dragging = false
      this.lastPointer = null
      this.startInertia()
    }
    el.addEventListener('pointerup', end)
    el.addEventListener('pointercancel', end)
    el.addEventListener('pointerleave', () => {
      this.cursor = null
      this.invalidate()
    })

    el.addEventListener(
      'wheel',
      (e) => {
        e.preventDefault()
        const r = el.getBoundingClientRect()
        const sx = e.clientX - r.left
        const sy = e.clientY - r.top
        // macOS/Chrome deliver trackpad pinch as wheel + ctrlKey.
        const factor = e.ctrlKey ? -e.deltaY * 0.02 : -e.deltaY * 0.0035
        this.zoomAt(sx, sy, factor)
      },
      { passive: false },
    )

    el.addEventListener('dblclick', (e) => {
      const r = el.getBoundingClientRect()
      this.zoomAt(e.clientX - r.left, e.clientY - r.top, 1)
    })
  }

  zoomAt(sx: number, sy: number, delta: number) {
    const [wx, wy] = this.screenToWorld(sx, sy)
    const next = clamp(this.zoom + delta, -1, MAX_ZOOM)
    if (next === this.zoom) return
    this.zoom = next
    // Keep the world point under the cursor pinned.
    const w = this.canvas.width / this.dpr
    const h = this.canvas.height / this.dpr
    this.cx = wx - (sx - w / 2) / this.scale
    this.cy = wy + (sy - h / 2) / this.scale
    this.clampCentre()
    this.invalidate()
    this.onViewChange?.()
  }

  private clampCentre() {
    const lim = WORLD_EXTENT * 1.1
    this.cx = clamp(this.cx, -lim, lim)
    this.cy = clamp(this.cy, -lim, lim)
  }

  private startInertia() {
    const friction = 0.92
    const step = () => {
      if (this.dragging) return
      this.vx *= friction
      this.vy *= friction
      if (Math.hypot(this.vx, this.vy) < 0.01) return
      this.cx -= (this.vx * 16) / this.scale
      this.cy += (this.vy * 16) / this.scale
      this.clampCentre()
      this.invalidate()
      requestAnimationFrame(step)
    }
    requestAnimationFrame(step)
  }

  setPois(pois: Poi[], labels: Array<{ label: string; kind: number }>) {
    this.pois = pois
    this.poiLabels = labels
    this.invalidate()
  }

  /** Enter ruler mode. Clicks add vertices until `endMeasure`. */
  startMeasure() {
    this.measure = { pts: [] }
    this.invalidate()
  }

  endMeasure() {
    this.measure = null
    this.onMeasure?.(0, null, 0)
    this.invalidate()
  }

  /** Total path length, and the bearing of the final leg. */
  private measureStats(): { total: number; bearing: number | null; leg: number } {
    const m = this.measure
    if (!m || m.pts.length === 0) return { total: 0, bearing: null, leg: 0 }
    const pts = m.pts.slice()
    if (this.cursor) pts.push(this.screenToWorld(this.cursor[0], this.cursor[1]))
    let total = 0
    for (let i = 1; i < pts.length; i++) {
      total += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1])
    }
    if (pts.length < 2) return { total: 0, bearing: null, leg: 0 }
    const a = pts[pts.length - 2]
    const b = pts[pts.length - 1]
    const leg = Math.hypot(b[0] - a[0], b[1] - a[1])
    // Valheim's compass has north at +y, and bearings read clockwise from it.
    const bearing = (Math.atan2(b[0] - a[0], b[1] - a[1]) * 180) / Math.PI
    return { total, bearing: (bearing + 360) % 360, leg }
  }

  togglePoi(kind: number, on: boolean) {
    if (on) this.poiEnabled.add(kind)
    else this.poiEnabled.delete(kind)
    this.hoveredPoi = null
    this.invalidate()
    this.onViewChange?.()
  }

  /** Nearest enabled marker within a constant screen-space radius. */
  private hitTestPoi(sx: number, sy: number): Poi | null {
    if (!this.pois.length) return null
    const w = this.canvas.width / this.dpr
    const h = this.canvas.height / this.dpr
    const scale = this.scale
    const R = 11
    let best: Poi | null = null
    let bestD = R * R
    for (const p of this.pois) {
      if (!this.poiEnabled.has(p.kind)) continue
      const px = (p.x - this.cx) * scale + w / 2
      const py = (this.cy - p.y) * scale + h / 2
      if (px < -R || py < -R || px > w + R || py > h + R) continue
      const d = (px - sx) ** 2 + (py - sy) ** 2
      if (d < bestD) {
        bestD = d
        best = p
      }
    }
    return best
  }

  private key(z: number, x: number, y: number) {
    return keyOf(this.pool.seed, this.mode, this.palette, z, x, y)
  }

  /** Falls back through ancestors so something is always on screen. */
  private drawAncestor(z: number, x: number, y: number, dx: number, dy: number, size: number) {
    for (let d = 1; d <= z; d++) {
      const az = z - d
      const ax = x >> d
      const ay = y >> d
      const bmp = this.cache.get(this.key(az, ax, ay))
      if (!bmp) continue
      const span = 1 << d
      const sub = TILE_SIZE / span
      const ox = (x & (span - 1)) * sub
      const oy = (y & (span - 1)) * sub
      this.ctx.drawImage(bmp, ox, oy, sub, sub, dx, dy, size, size)
      return true
    }
    return false
  }

  private loop = () => {
    // Schedule the next frame first: a throw inside draw() must never be able
    // to permanently stop the render loop.
    this.raf = requestAnimationFrame(this.loop)
    if (this.dirty) {
      this.dirty = false
      try {
        this.draw()
      } catch (err) {
        console.error('[map] draw failed', err)
      }
    }
  }

  private draw() {
    const ctx = this.ctx
    const W = this.canvas.width
    const H = this.canvas.height
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.fillStyle = '#05070d'
    ctx.fillRect(0, 0, W, H)
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0)
    ctx.imageSmoothingEnabled = true

    const w = W / this.dpr
    const h = H / this.dpr
    const scale = this.scale

    // Render one level finer on HiDPI so tiles map ~1:1 to device pixels.
    const zi = clamp(Math.round(this.zoom + Math.log2(this.dpr)), 0, MAX_ZOOM)
    const span = tileSpan(zi)
    const tilesPerAxis = 2 ** zi
    const drawn = span * scale

    // wy0 is the northern (top) edge of the viewport, wy1 the southern.
    const [wx0, wy0] = this.screenToWorld(0, 0)
    const [wx1, wy1] = this.screenToWorld(w, h)
    const tx0 = Math.max(0, Math.floor((wx0 + WORLD_EXTENT) / span))
    const ty0 = Math.max(0, Math.floor((WORLD_EXTENT - wy0) / span))
    const tx1 = Math.min(tilesPerAxis - 1, Math.floor((wx1 + WORLD_EXTENT) / span))
    const ty1 = Math.min(tilesPerAxis - 1, Math.floor((WORLD_EXTENT - wy1) / span))

    const wanted = new Set<string>()
    const requests: Array<{ x: number; y: number; pri: number }> = []
    let visible = 0

    for (let ty = ty0; ty <= ty1; ty++) {
      for (let tx = tx0; tx <= tx1; tx++) {
        visible++
        const wxo = -WORLD_EXTENT + tx * span
        const wyo = WORLD_EXTENT - ty * span
        const dx = (wxo - this.cx) * scale + w / 2
        const dy = (this.cy - wyo) * scale + h / 2
        const key = this.key(zi, tx, ty)
        wanted.add(key)

        const bmp = this.cache.get(key)
        if (bmp) {
          // Overdraw by a hair to avoid hairline seams from sub-pixel rounding.
          ctx.drawImage(bmp, dx, dy, drawn + 1, drawn + 1)
        } else {
          // Prefer the previous mode/palette at this exact tile; it is the
          // same geometry, so switching never blanks the map.
          const prev =
            this.prevVariant &&
            this.cache.get(
              keyOf(this.pool.seed, this.prevVariant[0], this.prevVariant[1], zi, tx, ty),
            )
          if (prev) ctx.drawImage(prev, dx, dy, drawn + 1, drawn + 1)
          else this.drawAncestor(zi, tx, ty, dx, dy, drawn + 1)
          const ccx = dx + drawn / 2 - w / 2
          const ccy = dy + drawn / 2 - h / 2
          requests.push({ x: tx, y: ty, pri: Math.hypot(ccx, ccy) })
        }
      }
    }

    // Nearest-to-centre first, and drop work for tiles no longer wanted.
    this.pool.cancelExcept(wanted)
    requests.sort((a, b) => a.pri - b.pri)
    const gen = this.generation
    for (const r of requests) {
      const key = this.key(zi, r.x, r.y)
      if (this.cache.has(key) || this.requested.has(key)) continue
      this.requested.add(key)
      this.pool
        .request(
          {
            type: 'tile',
            id: key,
            z: zi,
            x: r.x,
            y: r.y,
            size: TILE_SIZE,
            mode: this.mode,
            palette: this.palette,
          },
          r.pri,
        )
        .then((b) => {
          if (gen !== this.generation) {
            b.close()
            return
          }
          this.cache.set(key, b)
          this.invalidate()
        })
        .catch(() => {})
        .finally(() => this.requested.delete(key))
    }

    this.drawOverlay(ctx, w, h, scale)
    this.drawMeasure(ctx)

    this.stats.visibleTiles = visible
    this.stats.cachedTiles = this.cache.count
    this.stats.cacheMB = this.cache.megabytes
    this.stats.pending = this.pool.busy
    this.stats.mpp = metersPerPixel(zi) / (drawn / TILE_SIZE)
    this.onStats?.(this.stats)
  }

  /** Ruler path, drawn over everything else so it survives any basemap. */
  private drawMeasure(ctx: CanvasRenderingContext2D) {
    const m = this.measure
    if (!m || m.pts.length === 0) return
    const pts = m.pts.map(([x, y]) => this.worldToScreen(x, y))
    if (this.cursor) pts.push([this.cursor[0], this.cursor[1]])

    ctx.save()
    ctx.lineJoin = 'round'
    // Dark under-stroke so the line reads over snow and pale ice too.
    ctx.strokeStyle = 'rgba(0,0,0,.65)'
    ctx.lineWidth = 3.5
    ctx.beginPath()
    ctx.moveTo(pts[0][0], pts[0][1])
    for (const p of pts.slice(1)) ctx.lineTo(p[0], p[1])
    ctx.stroke()
    ctx.strokeStyle = '#ffd77a'
    ctx.lineWidth = 1.25
    ctx.setLineDash([5, 4])
    ctx.stroke()
    ctx.setLineDash([])

    for (const [x, y] of pts) {
      ctx.beginPath()
      ctx.arc(x, y, 2.6, 0, Math.PI * 2)
      ctx.fillStyle = '#0a0e16'
      ctx.fill()
      ctx.strokeStyle = '#ffd77a'
      ctx.lineWidth = 1.2
      ctx.stroke()
    }

    // Per-leg distance, so a multi-leg sailing route is readable leg by leg.
    ctx.font = '10px ui-monospace, monospace'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    for (let i = 1; i < pts.length; i++) {
      const a = pts[i - 1]
      const b = pts[i]
      const wa = i - 1 < m.pts.length ? m.pts[i - 1] : null
      const wb = i < m.pts.length ? m.pts[i] : this.cursor ? this.screenToWorld(this.cursor[0], this.cursor[1]) : null
      if (!wa || !wb) continue
      const d = Math.hypot(wb[0] - wa[0], wb[1] - wa[1])
      const label = d >= 1000 ? `${(d / 1000).toFixed(2)} km` : `${Math.round(d)} m`
      const mx = (a[0] + b[0]) / 2
      const my = (a[1] + b[1]) / 2
      const tw = ctx.measureText(label).width
      ctx.fillStyle = 'rgba(6,10,18,.82)'
      ctx.fillRect(mx - tw / 2 - 4, my - 8, tw + 8, 15)
      ctx.fillStyle = '#ffd77a'
      ctx.fillText(label, mx, my)
    }
    ctx.restore()
  }

  private drawOverlay(ctx: CanvasRenderingContext2D, w: number, h: number, scale: number) {
    const toScreen = (wx: number, wy: number): [number, number] => [
      (wx - this.cx) * scale + w / 2,
      (this.cy - wy) * scale + h / 2,
    ]

    ctx.save()
    ctx.font =
      '9px ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace'
    ctx.textBaseline = 'top'

    // ---- world graticule, snapped to round metres --------------------------
    if (this.showGrid) {
      const spacing = niceStep(120 / scale)
      const [wl, wt] = this.screenToWorld(0, 0)
      const [wr, wb] = this.screenToWorld(w, h)

      ctx.lineWidth = 1
      ctx.strokeStyle = 'rgba(120, 220, 255, 0.055)'
      ctx.fillStyle = 'rgba(140, 225, 255, 0.38)'
      ctx.beginPath()
      for (let gx = Math.ceil(wl / spacing) * spacing; gx <= wr; gx += spacing) {
        const x = Math.round(toScreen(gx, 0)[0]) + 0.5
        ctx.moveTo(x, 0)
        ctx.lineTo(x, h)
      }
      for (let gy = Math.floor(wt / spacing) * spacing; gy >= wb; gy -= spacing) {
        const y = Math.round(toScreen(0, gy)[1]) + 0.5
        ctx.moveTo(0, y)
        ctx.lineTo(w, y)
      }
      ctx.stroke()

      // Edge rulers: ticks + coordinate labels along top and left.
      ctx.strokeStyle = 'rgba(140, 225, 255, 0.3)'
      ctx.beginPath()
      for (let gx = Math.ceil(wl / spacing) * spacing; gx <= wr; gx += spacing) {
        const x = Math.round(toScreen(gx, 0)[0]) + 0.5
        ctx.moveTo(x, 0)
        ctx.lineTo(x, 7)
        ctx.fillText(fmtCoord(gx), x + 4, 5)
      }
      for (let gy = Math.floor(wt / spacing) * spacing; gy >= wb; gy -= spacing) {
        const y = Math.round(toScreen(0, gy)[1]) + 0.5
        ctx.moveTo(0, y)
        ctx.lineTo(7, y)
        ctx.fillText(fmtCoord(gy), 10, y + 3)
      }
      ctx.stroke()
    }

    // ---- world boundary ----------------------------------------------------
    const [ox, oy] = toScreen(0, 0)
    ctx.strokeStyle = 'rgba(150, 230, 255, 0.22)'
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.arc(ox, oy, 10000 * scale, 0, Math.PI * 2)
    ctx.stroke()

    ctx.setLineDash([3, 5])
    ctx.strokeStyle = 'rgba(150, 230, 255, 0.13)'
    ctx.beginPath()
    ctx.arc(ox, oy, WORLD_EXTENT * scale, 0, Math.PI * 2)
    ctx.stroke()
    ctx.setLineDash([])

    // ---- spawn ------------------------------------------------------------
    ctx.strokeStyle = '#e8c07a'
    ctx.lineWidth = 1.25
    ctx.beginPath()
    ctx.arc(ox, oy, 7, 0, Math.PI * 2)
    ctx.moveTo(ox - 12, oy)
    ctx.lineTo(ox - 3, oy)
    ctx.moveTo(ox + 3, oy)
    ctx.lineTo(ox + 12, oy)
    ctx.moveTo(ox, oy - 12)
    ctx.lineTo(ox, oy - 3)
    ctx.moveTo(ox, oy + 3)
    ctx.lineTo(ox, oy + 12)
    ctx.stroke()
    ctx.fillStyle = 'rgba(232, 192, 122, 0.9)'
    ctx.fillText('SPAWN 0,0', ox + 15, oy - 4)

    // ---- cursor crosshair --------------------------------------------------
    if (this.cursor && !this.dragging) {
      const [sx, sy] = this.cursor
      ctx.strokeStyle = 'rgba(150, 235, 255, 0.28)'
      ctx.setLineDash([2, 4])
      ctx.beginPath()
      ctx.moveTo(0, Math.round(sy) + 0.5)
      ctx.lineTo(w, Math.round(sy) + 0.5)
      ctx.moveTo(Math.round(sx) + 0.5, 0)
      ctx.lineTo(Math.round(sx) + 0.5, h)
      ctx.stroke()
      ctx.setLineDash([])
      ctx.strokeStyle = 'rgba(150, 235, 255, 0.75)'
      ctx.beginPath()
      ctx.arc(sx, sy, 10, 0, Math.PI * 2)
      ctx.stroke()
    }

    // ---- points of interest -------------------------------------------------
    this.drawPois(ctx, w, h, scale)

    // ---- corner brackets ---------------------------------------------------
    const b = 16
    const pad = 5
    ctx.strokeStyle = 'rgba(150, 235, 255, 0.45)'
    ctx.lineWidth = 1
    ctx.beginPath()
    for (const [cx2, cy2, dx2, dy2] of [
      [pad, pad, 1, 1],
      [w - pad, pad, -1, 1],
      [pad, h - pad, 1, -1],
      [w - pad, h - pad, -1, -1],
    ] as const) {
      ctx.moveTo(cx2, cy2 + dy2 * b)
      ctx.lineTo(cx2, cy2)
      ctx.lineTo(cx2 + dx2 * b, cy2)
    }
    ctx.stroke()

    // ---- scale bar + compass ----------------------------------------------
    const barMetres = niceStep(150 / scale)
    const barPx = barMetres * scale
    const bx = w - pad - 20 - barPx
    const by = h - pad - 22
    ctx.strokeStyle = 'rgba(210, 240, 255, 0.7)'
    ctx.beginPath()
    ctx.moveTo(bx, by - 4)
    ctx.lineTo(bx, by)
    ctx.lineTo(bx + barPx, by)
    ctx.lineTo(bx + barPx, by - 4)
    ctx.stroke()
    ctx.fillStyle = 'rgba(210, 240, 255, 0.75)'
    ctx.fillText(`${fmtCoord(barMetres)} m`, bx, by + 4)

    ctx.strokeStyle = 'rgba(210, 240, 255, 0.55)'
    ctx.beginPath()
    ctx.moveTo(w - pad - 10, by - 2)
    ctx.lineTo(w - pad - 10, by - 16)
    ctx.moveTo(w - pad - 14, by - 12)
    ctx.lineTo(w - pad - 10, by - 17)
    ctx.lineTo(w - pad - 6, by - 12)
    ctx.stroke()
    ctx.fillText('N', w - pad - 13, by - 1)

    ctx.restore()
  }

  /** Markers are drawn as flat geometric glyphs so they read as instrument
   *  symbology rather than map-app pins, and stay legible on any ground. */
  private drawPois(ctx: CanvasRenderingContext2D, w: number, h: number, scale: number) {
    if (!this.pois.length) return
    const labelZoom = this.zoom > 3.4

    for (const p of this.pois) {
      if (!this.poiEnabled.has(p.kind)) continue
      const px = (p.x - this.cx) * scale + w / 2
      const py = (this.cy - p.y) * scale + h / 2
      if (px < -20 || py < -20 || px > w + 20 || py > h + 20) continue

      const spec = POI_KINDS[p.kind]
      const hot = this.hoveredPoi === p
      const r = hot ? 7.5 : 5.5

      // Dark halo first so the glyph survives white mountains and pale ice.
      ctx.lineWidth = 3
      ctx.strokeStyle = 'rgba(2, 5, 11, 0.85)'
      glyph(ctx, spec.glyph, px, py, r)
      ctx.stroke()

      ctx.lineWidth = hot ? 1.6 : 1.2
      ctx.strokeStyle = spec.color
      ctx.fillStyle = hot ? spec.color : 'rgba(2, 5, 11, 0.55)'
      glyph(ctx, spec.glyph, px, py, r)
      ctx.fill()
      ctx.stroke()

      const named = this.poiLabels[p.cfg]?.label
      if (named && (hot || (labelZoom && p.kind <= 2))) {
        const text = named.toUpperCase()
        ctx.font = '9px ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace'
        const tw = ctx.measureText(text).width
        // Leader line out to a label plate, technical-drawing style.
        ctx.strokeStyle = hot ? spec.color : 'rgba(150, 235, 255, 0.5)'
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(px + r + 1, py)
        ctx.lineTo(px + r + 8, py)
        ctx.stroke()
        ctx.fillStyle = 'rgba(2, 5, 11, 0.82)'
        ctx.fillRect(px + r + 8, py - 7, tw + 8, 14)
        ctx.strokeStyle = hot ? spec.color : 'rgba(150, 235, 255, 0.28)'
        ctx.strokeRect(px + r + 8.5, py - 6.5, tw + 7, 13)
        ctx.fillStyle = hot ? '#ffffff' : 'rgba(200, 240, 255, 0.85)'
        ctx.textBaseline = 'middle'
        ctx.fillText(text, px + r + 12, py + 0.5)
        ctx.textBaseline = 'top'
      }
    }
  }

  destroy() {
    cancelAnimationFrame(this.raf)
    this.cache.clear()
  }
}
