import { POI_KINDS } from './protocol'

/**
 * The whole view encoded in the address bar.
 *
 * The existing tool in this space encodes seed, pan, zoom and view mode, and
 * people rely on that: seed posts are usually a screenshot plus a deep link.
 * Ours previously carried only `?seed=`, so there was no way to point someone
 * at a specific place on a map.
 *
 * Everything is optional and everything has a default, so a bare `?seed=x`
 * still works and a link written by an older build still opens.
 */
export interface ViewState {
  seed: string
  cx: number
  cy: number
  zoom: number
  mode: number
  palette: number
  three: boolean
  grid: boolean
  /** Enabled marker categories, as a bitmask over `POI_KINDS` ids. */
  markers: number
}

const round = (v: number, dp: number) => {
  const f = 10 ** dp
  return Math.round(v * f) / f
}

export function encode(s: ViewState): URLSearchParams {
  const p = new URLSearchParams()
  p.set('seed', s.seed)
  // Metre precision for position is well past what anyone can see, and keeps
  // the link short enough to paste into a forum post without wrapping.
  if (s.cx || s.cy) p.set('at', `${Math.round(s.cx)},${Math.round(s.cy)}`)
  if (s.zoom) p.set('z', String(round(s.zoom, 2)))
  if (s.mode) p.set('m', String(s.mode))
  if (s.palette) p.set('p', String(s.palette))
  if (s.three) p.set('v', '3d')
  if (!s.grid) p.set('g', '0')
  if (s.markers !== defaultMarkers()) p.set('k', s.markers.toString(36))
  return p
}

export function defaultMarkers(): number {
  let m = 0
  for (const k of POI_KINDS) if (k.defaultOn) m |= 1 << k.id
  return m
}

export function decode(search: string, fallbackSeed: string): ViewState {
  const p = new URLSearchParams(search)
  const num = (key: string, def: number) => {
    const raw = p.get(key)
    if (raw === null) return def
    const v = Number(raw)
    return Number.isFinite(v) ? v : def
  }
  let cx = 0
  let cy = 0
  const at = p.get('at')
  if (at) {
    const [a, b] = at.split(',').map(Number)
    if (Number.isFinite(a) && Number.isFinite(b)) {
      cx = a
      cy = b
    }
  }
  const k = p.get('k')
  const markers = k === null ? defaultMarkers() : parseInt(k, 36)
  return {
    seed: p.get('seed') || fallbackSeed,
    cx,
    cy,
    zoom: num('z', 0),
    mode: num('m', 0),
    palette: num('p', 0),
    three: p.get('v') === '3d',
    grid: p.get('g') !== '0',
    markers: Number.isFinite(markers) ? markers : defaultMarkers(),
  }
}

/**
 * Writes state to the address bar without touching history. `pushState` here
 * would add an entry on every pan frame and make the back button useless.
 */
export function write(s: ViewState) {
  const url = new URL(location.href)
  url.search = encode(s).toString()
  history.replaceState(null, '', url)
}
