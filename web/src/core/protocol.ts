/** Messages exchanged with the tile workers. */

export interface InitReq {
  type: 'init'
  seedName: string
  worldGenVersion: number
}

export interface TileReq {
  type: 'tile'
  /** Cache key, echoed back so results can be matched or discarded. */
  id: string
  z: number
  x: number
  y: number
  size: number
  mode: number
  palette: number
}

export interface QueryReq {
  type: 'query'
  id: number
  wx: number
  wy: number
}

export interface HistReq {
  type: 'hist'
  id: number
  ox: number
  oy: number
  spanX: number
  spanY: number
  n: number
}

export interface LocReq {
  type: 'locations'
  id: number
  /** Bitmask over `POI_KINDS` ids. Only these categories come back; placement
   *  still runs for all of them, because types compete for the same zones. */
  kinds: number
}

export interface TerrainReq {
  type: 'terrain'
  id: number
  ox: number
  oy: number
  span: number
  /** Height lattice resolution per axis. */
  grid: number
  /** Texture resolution per axis. */
  tex: number
  mode: number
  palette: number
}

export type Req = InitReq | TileReq | QueryReq | HistReq | LocReq | TerrainReq | SearchReq

export interface InitRes {
  type: 'ready'
  seed: number
  /** Pregeneration time in ms, for the perf readout. */
  ms: number
}

export interface TileRes {
  type: 'tile'
  id: string
  bitmap: ImageBitmap
  ms: number
}

export interface QueryRes {
  type: 'query'
  id: number
  biome: number
  height: number
}

export interface HistRes {
  type: 'hist'
  id: number
  counts: Uint32Array
}

export interface SearchReq {
  type: 'search'
  start: number
  count: number
  radius: number
  nearMask: number
  minHomeKm2: number
  homeMask: number
}

export interface SearchRes {
  type: 'search'
  start: number
  count: number
  hits: string
}

export interface SearchHit {
  phrase: string
  seed: number
  homeKm2: number
  biomes: number
}

export interface LocProgressRes {
  type: 'locProgress'
  id: number
  /** 0..1 across location types, not placements. */
  progress: number
  /** Present only on milestone steps; same layout as `LocRes.data`. */
  data?: Float32Array
  /** Sent alongside `data` so early markers can be labelled immediately. */
  table?: string
}

export interface LocRes {
  type: 'locations'
  id: number
  /** Per-category totals for every category, including unfetched ones. */
  counts: number[]
  /** Flattened [kind, cfgIndex, x, y, reachable] per entry. */
  data: Float32Array
  table: string
  /** Seed report JSON — see `World::report` in Rust. */
  report: string
}

export interface TerrainRes {
  type: 'terrain'
  id: number
  heights: Float32Array
  grid: number
  span: number
  bitmap: ImageBitmap
}

export type Res =
  | InitRes
  | TileRes
  | QueryRes
  | HistRes
  | LocRes
  | LocProgressRes
  | SearchRes
  | TerrainRes

/** Full world extent per axis, matching WorldGenerator's waterEdge. */
export const WORLD_EXTENT = 10500
export const WORLD_SPAN = WORLD_EXTENT * 2
export const TILE_SIZE = 256
export const MAX_ZOOM = 8

/** World units covered by one tile edge at this zoom. */
export function tileSpan(z: number): number {
  return WORLD_SPAN / 2 ** z
}

/**
 * World-space top-left of a tile. Screen Y grows downward while world Y
 * (north) grows upward, so tile row 0 is the north edge and the returned
 * `oy` is the tile's NORTH edge — the renderer walks southward from it.
 */
export function tileOrigin(z: number, x: number, y: number): [number, number] {
  const s = tileSpan(z)
  return [-WORLD_EXTENT + x * s, WORLD_EXTENT - y * s]
}

export function metersPerPixel(z: number, size = TILE_SIZE): number {
  return tileSpan(z) / size
}

/** Biome ordinals as used by the histogram, in display order. */
export const BIOME_ORDER: Array<[number, string]> = [
  [1, 'MEADOWS'],
  [4, 'BLACK FOREST'],
  [2, 'SWAMP'],
  [3, 'MOUNTAIN'],
  [5, 'PLAINS'],
  [9, 'MISTLANDS'],
  [6, 'ASHLANDS'],
  [7, 'DEEP NORTH'],
  [8, 'OCEAN'],
]

export const BIOME_NAMES: Record<number, string> = {
  0: 'None',
  1: 'Meadows',
  2: 'Swamp',
  4: 'Mountain',
  8: 'Black Forest',
  16: 'Plains',
  32: 'Ashlands',
  64: 'Deep North',
  256: 'Ocean',
  512: 'Mistlands',
}

/** Sea level in world Y units. */
export const WATER_LEVEL = 30

/** POI categories, matching the Rust `Kind` enum ordinals. */
export const POI_KINDS: Array<{
  id: number
  name: string
  color: string
  glyph: string
  /** Categories left off by default: with 183 location types a world holds
   *  ~12 000 sites, and switching them all on at once buries the handful of
   *  markers anyone actually navigates by. */
  defaultOn?: boolean
}> = [
  { id: 0, name: 'SPAWN', color: '#ffffff', glyph: 'spawn', defaultOn: true },
  { id: 1, name: 'BOSS', color: '#ff7a52', glyph: 'diamond', defaultOn: true },
  { id: 2, name: 'TRADER', color: '#e8c07a', glyph: 'coin', defaultOn: true },
  { id: 3, name: 'CRYPT', color: '#9a7cff', glyph: 'square' },
  { id: 4, name: 'CAMP', color: '#ff9ad5', glyph: 'triangle' },
  { id: 5, name: 'CAVE', color: '#7fe3c4', glyph: 'arch' },
  { id: 6, name: 'MINE', color: '#6fd0ff', glyph: 'hex' },
  { id: 7, name: 'FORTRESS', color: '#ffb03a', glyph: 'keep' },
  { id: 8, name: 'RUNESTONE', color: '#c9d4ff', glyph: 'rune' },
  { id: 9, name: 'RUIN', color: '#97a2ad', glyph: 'ruin' },
  { id: 10, name: 'VILLAGE', color: '#d6a06a', glyph: 'house' },
  { id: 11, name: 'WRECK', color: '#7aa6c2', glyph: 'hull' },
  { id: 12, name: 'MONUMENT', color: '#b9a6e0', glyph: 'menhir' },
  { id: 13, name: 'RESOURCE', color: '#8fd94a', glyph: 'node' },
  { id: 14, name: 'MYSTERY', color: '#ff5fa8', glyph: 'sigil' },
]

export interface Poi {
  kind: number
  cfg: number
  x: number
  y: number
  /** True when this site shares the spawn landmass — i.e. reachable on foot. */
  reachable: boolean
}

/** One boss or trader, as the seed report describes it. */
export interface ReportSite {
  label: string
  kind: number
  dist: number
  x: number
  y: number
  reachable: boolean
}

export interface SeedReport {
  spawnAreaKm2: number
  largestKm2: number
  landmasses: number
  spawnIsLargest: boolean
  /** How many of the listed bosses/traders share the spawn landmass. */
  reachable: number
  total: number
  sites: ReportSite[]
  counts: number[]
}
