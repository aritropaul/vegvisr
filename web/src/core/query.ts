import type {
  HistRes,
  LocProgressRes,
  LocRes,
  Poi,
  QueryRes,
  Req,
  Res,
  SeedReport,
  TerrainRes,
} from './protocol'

/**
 * A single worker dedicated to point lookups, kept out of the tile pool so a
 * cursor query never queues behind a render.
 */
/** Flattened [kind, cfg, x, y, reachable] -> objects. */
function decodePois(data: Float32Array): Poi[] {
  const pois: Poi[] = []
  for (let i = 0; i < data.length; i += 5) {
    pois.push({
      kind: data[i],
      cfg: data[i + 1],
      x: data[i + 2],
      y: data[i + 3],
      reachable: data[i + 4] === 1,
    })
  }
  return pois
}

export class QueryWorker {
  private worker: Worker
  private next = 0
  private pending = new Map<number, (r: QueryRes) => void>()
  private pendingHist = new Map<number, (r: HistRes) => void>()
  private pendingLoc = new Map<number, (r: LocRes) => void>()
  /** Called as placement advances; `data` arrives only on milestone steps. */
  onLocationProgress?: (
    progress: number,
    pois: Poi[] | null,
    table: Array<{ label: string; kind: number }> | null,
  ) => void
  private pendingTerrain = new Map<number, (r: TerrainRes) => void>()
  private ready: Promise<void> | null = null

  constructor() {
    this.worker = new Worker(new URL('../workers/tile.worker.ts', import.meta.url), {
      type: 'module',
    })
    this.worker.onmessage = (e: MessageEvent<Res>) => {
      const res = e.data
      if (res.type === 'ready') {
        this.resolveReady?.()
        return
      }
      if (res.type === 'query') {
        this.pending.get(res.id)?.(res)
        this.pending.delete(res.id)
      }
      if (res.type === 'hist') {
        this.pendingHist.get(res.id)?.(res)
        this.pendingHist.delete(res.id)
      }
      if (res.type === 'locProgress') {
        const r = res as LocProgressRes
        this.onLocationProgress?.(
          r.progress,
          r.data ? decodePois(r.data) : null,
          r.table ? JSON.parse(r.table) : null,
        )
        return
      }
      if (res.type === 'locations') {
        this.pendingLoc.get(res.id)?.(res)
        this.pendingLoc.delete(res.id)
      }
      if (res.type === 'terrain') {
        this.pendingTerrain.get(res.id)?.(res)
        this.pendingTerrain.delete(res.id)
      }
    }
  }

  private resolveReady: (() => void) | null = null

  init(seedName: string, worldGenVersion: number): Promise<void> {
    this.ready = new Promise((r) => (this.resolveReady = r))
    const req: Req = { type: 'init', seedName, worldGenVersion }
    this.worker.postMessage(req)
    return this.ready
  }

  /** Height lattice plus a matching surface texture for the 3D view. */
  async terrain(
    ox: number,
    oy: number,
    span: number,
    grid: number,
    tex: number,
    mode: number,
    palette: number,
  ): Promise<TerrainRes> {
    await this.ready
    const id = ++this.next
    return new Promise((resolve) => {
      this.pendingTerrain.set(id, resolve)
      const req: Req = { type: 'terrain', id, ox, oy, span, grid, tex, mode, palette }
      this.worker.postMessage(req)
    })
  }

  /** Runs the full location placement pass. One-time per seed. */
  async locations(kinds: number): Promise<{
    pois: Poi[]
    table: Array<{ label: string; kind: number }>
    report: SeedReport
    counts: number[]
  }> {
    await this.ready
    const id = ++this.next
    const res = await new Promise<LocRes>((resolve) => {
      this.pendingLoc.set(id, resolve)
      const req: Req = { type: 'locations', id, kinds }
      this.worker.postMessage(req)
    })
    return {
      pois: decodePois(res.data),
      table: JSON.parse(res.table),
      report: JSON.parse(res.report),
      counts: res.counts,
    }
  }

  /** Biome composition of a square region, sampled on an n x n lattice. */
  async histogram(
    ox: number,
    oy: number,
    spanX: number,
    spanY: number,
    n: number,
  ): Promise<Uint32Array> {
    await this.ready
    const id = ++this.next
    return new Promise((resolve) => {
      this.pendingHist.set(id, (r) => resolve(r.counts))
      const req: Req = { type: 'hist', id, ox, oy, spanX, spanY, n }
      this.worker.postMessage(req)
    })
  }

  async query(wx: number, wy: number): Promise<QueryRes> {
    await this.ready
    const id = ++this.next
    return new Promise((resolve) => {
      this.pending.set(id, resolve)
      const req: Req = { type: 'query', id, wx, wy }
      this.worker.postMessage(req)
    })
  }
}
