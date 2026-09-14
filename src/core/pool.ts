import type { InitRes, Req, Res, SearchHit, SearchRes, TileRes } from './protocol'

type TileMsg = Extract<Req, { type: 'tile' }>

/** Candidates per batch. ~1 s of work: small enough that stopping feels
 *  immediate, large enough that postMessage overhead is noise. */
const SEARCH_BATCH = 8

interface Job {
  req: TileMsg
  priority: number
  resolve: (b: ImageBitmap) => void
  reject: (e: unknown) => void
}

/**
 * Pool of independent workers, each holding its own WASM instance and its own
 * linear memory. Deliberately avoids SharedArrayBuffer so the app needs no
 * COOP/COEP headers and can be hosted anywhere.
 */
export class TilePool {
  private workers: Worker[] = []
  private idle: Worker[] = []
  private queue: Job[] = []
  /** Worker-keyed, so a worker is returned to the idle list exactly once. */
  private busyBy = new Map<Worker, Job>()
  /** Deduplicates concurrent requests for the same tile. */
  private pending = new Map<string, Promise<ImageBitmap>>()
  private cancelled = new Set<string>()
  private onTileMs?: (ms: number) => void

  /** Background seed search. Batches go only to workers with no tile work, so
   *  panning the map always wins over a search running behind it. */
  private search: {
    next: number
    scanned: number
    inFlight: number
    params: Omit<Extract<Req, { type: 'search' }>, 'type' | 'start' | 'count'>
    onHit: (h: SearchHit[], scanned: number) => void
  } | null = null

  readonly size: number
  seed = 0
  pregenMs = 0

  constructor(size = Math.max(2, (navigator.hardwareConcurrency || 4) - 1)) {
    this.size = size
    for (let i = 0; i < size; i++) {
      const w = new Worker(new URL('../workers/tile.worker.ts', import.meta.url), {
        type: 'module',
      })
      w.onmessage = (e: MessageEvent<Res>) => this.handle(w, e.data)
      w.onerror = (e) => console.error('[tile worker]', e.message, e.filename, e.lineno)
      this.workers.push(w)
    }
  }

  setTileMsHook(fn: (ms: number) => void) {
    this.onTileMs = fn
  }

  private readyResolve: (() => void) | null = null

  /** Builds the world in every worker; resolves once all have pregenerated. */
  init(seedName: string, worldGenVersion: number): Promise<void> {
    this.reset()
    let remaining = this.workers.length
    return new Promise((resolve) => {
      this.readyResolve = () => {
        if (--remaining === 0) resolve()
      }
      const req: Req = { type: 'init', seedName, worldGenVersion }
      for (const w of this.workers) w.postMessage(req)
    })
  }

  private reset() {
    for (const j of this.queue) j.reject(new Error('cancelled'))
    this.queue = []
    this.busyBy.clear()
    this.pending.clear()
    this.cancelled.clear()
    this.idle = []
  }

  private handle(w: Worker, res: Res) {
    if (res.type === 'ready') {
      const r = res as InitRes
      this.seed = r.seed
      this.pregenMs = Math.max(this.pregenMs, r.ms)
      this.markIdle(w)
      this.readyResolve?.()
      this.pump()
      return
    }
    if (res.type === 'search') {
      const r = res as SearchRes
      this.markIdle(w)
      if (this.search) {
        this.search.inFlight--
        this.search.scanned += r.count
        const hits = JSON.parse(r.hits) as SearchHit[]
        this.search.onHit(hits, this.search.scanned)
      }
      this.pump()
      return
    }
    if (res.type !== 'tile') return

    const t = res as TileRes
    const job = this.busyBy.get(w)
    this.busyBy.delete(w)
    this.markIdle(w)
    this.pending.delete(t.id)

    if (job && !this.cancelled.has(t.id)) {
      this.onTileMs?.(t.ms)
      job.resolve(t.bitmap)
    } else {
      // Nobody wants it any more; free the backing memory immediately.
      t.bitmap.close()
      job?.reject(new Error('cancelled'))
    }
    this.cancelled.delete(t.id)
    this.pump()
  }

  /**
   * Requests a tile. Repeat calls for a tile already queued or in flight
   * return the existing promise instead of enqueuing duplicate work.
   */
  request(req: TileMsg, priority: number): Promise<ImageBitmap> {
    const existing = this.pending.get(req.id)
    if (existing) {
      this.cancelled.delete(req.id)
      return existing
    }
    const p = new Promise<ImageBitmap>((resolve, reject) => {
      const job: Job = { req, priority, resolve, reject }
      // Keep the queue ordered so tiles nearest the viewport centre run first.
      const i = this.queue.findIndex((j) => j.priority > priority)
      if (i === -1) this.queue.push(job)
      else this.queue.splice(i, 0, job)
    })
    this.pending.set(req.id, p)
    this.pump()
    return p
  }

  /** Drops queued work and discards in-flight results for off-screen tiles. */
  cancelExcept(keep: Set<string>) {
    this.queue = this.queue.filter((j) => {
      if (keep.has(j.req.id)) return true
      j.reject(new Error('cancelled'))
      this.pending.delete(j.req.id)
      return false
    })
    for (const job of this.busyBy.values()) {
      if (!keep.has(job.req.id)) this.cancelled.add(job.req.id)
    }
  }

  /**
   * Return a worker to the idle list, at most once.
   *
   * `busyBy` is worker-keyed — one job per worker — so a worker sitting in
   * `idle` twice gets handed two jobs, the second `busyBy.set` overwrites the
   * first, and the first response then resolves the *second* job's promise.
   * The bitmap lands under the wrong tile key and the map draws a patchwork of
   * correct-looking tiles in the wrong places.
   *
   * Duplicates were reachable two ways. `init()` clears `idle` and `busyBy`
   * while work is still in flight, so a worker finishing an old tile pushes
   * itself back, then pushes again when it answers the new `init`. Seed search
   * added a third push site and made it routine.
   */
  private markIdle(w: Worker) {
    if (this.busyBy.has(w) || this.idle.includes(w)) return
    this.idle.push(w)
  }

  private pump() {
    while (this.idle.length && this.queue.length) {
      const w = this.idle.pop()!
      const job = this.queue.shift()!
      this.busyBy.set(w, job)
      w.postMessage(job.req)
    }
    // Only feed the search once every tile is placed, so a search never makes
    // the map feel slow. A batch is ~1 s, which bounds how long a tile can be
    // stuck behind one.
    while (this.search && this.idle.length && !this.queue.length) {
      const w = this.idle.pop()!
      const s = this.search
      const req: Req = { type: 'search', start: s.next, count: SEARCH_BATCH, ...s.params }
      s.next += SEARCH_BATCH
      s.inFlight++
      w.postMessage(req)
    }
  }

  startSearch(
    params: Omit<Extract<Req, { type: 'search' }>, 'type' | 'start' | 'count'>,
    onHit: (hits: SearchHit[], scanned: number) => void,
  ) {
    this.search = { next: 0, scanned: 0, inFlight: 0, params, onHit }
    this.pump()
  }

  stopSearch() {
    this.search = null
  }

  get searching(): boolean {
    return this.search !== null
  }

  get busy(): number {
    return this.busyBy.size + this.queue.length
  }

  debugState() {
    return {
      workers: this.workers.length,
      idle: this.idle.length,
      queued: this.queue.length,
      inflight: this.busyBy.size,
      pending: this.pending.size,
      seed: this.seed,
      pregenMs: this.pregenMs,
    }
  }
}
