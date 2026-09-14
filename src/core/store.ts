/**
 * Persistent tile store, backed by the Cache API.
 *
 * A tile is a pure function of `seed:mode:palette:z/x/y` — the generator is
 * deterministic, so a tile that has been computed once is correct forever.
 * Until now they lived only in an in-memory LRU, which meant every reload,
 * every revisit and every "back" regenerated terrain the machine had already
 * produced. That is the single most wasteful thing this app did.
 *
 * Cached tiles cost ~10 ms to decode instead of ~60 ms to generate, and cost
 * no worker time at all, so they also stop competing with the tiles that do
 * need generating.
 *
 * Everything here fails soft. The Cache API is unavailable in some contexts
 * (private windows, storage pressure, embedded webviews) and can throw at any
 * call; a miss just means the tile gets generated as before.
 */

const CACHE_NAME = 'valheim-tiles-v1'

/** Synthetic origin. Never fetched — it only namespaces the cache keys. */
const keyUrl = (key: string) => `https://tiles.invalid/${encodeURIComponent(key)}`

export class TileStore {
  private cache: Cache | null = null
  private opening: Promise<Cache | null> | null = null
  /** Keys known to be absent, so a repeated miss doesn't re-query storage. */
  private absent = new Set<string>()
  private writing = new Set<string>()
  private canvas: OffscreenCanvas | null = null

  readonly available = typeof caches !== 'undefined' && typeof OffscreenCanvas !== 'undefined'

  private async open(): Promise<Cache | null> {
    if (this.cache) return this.cache
    if (!this.available) return null
    if (!this.opening) {
      this.opening = caches
        .open(CACHE_NAME)
        .then((c) => (this.cache = c))
        .catch(() => null)
    }
    return this.opening
  }

  /** Synchronous "we already looked and it wasn't there". Lets the render
   *  path decide to ask a worker without awaiting storage again. */
  knownAbsent(key: string): boolean {
    return this.absent.has(key)
  }

  /** A previously stored tile, or null. Never throws. */
  async get(key: string): Promise<ImageBitmap | null> {
    if (this.absent.has(key)) return null
    try {
      const cache = await this.open()
      if (!cache) return null
      const res = await cache.match(keyUrl(key))
      if (!res) {
        this.absent.add(key)
        return null
      }
      return await createImageBitmap(await res.blob())
    } catch {
      this.absent.add(key)
      return null
    }
  }

  /**
   * Store a tile. Encoding to PNG costs a few ms of main-thread time, so this
   * is deliberately called from idle time rather than on the render path — a
   * tile that never gets persisted only costs a regeneration later.
   */
  async put(key: string, bitmap: ImageBitmap): Promise<void> {
    if (!this.available || this.writing.has(key)) return
    this.writing.add(key)
    try {
      const cache = await this.open()
      if (!cache) return
      if (!this.canvas || this.canvas.width !== bitmap.width) {
        this.canvas = new OffscreenCanvas(bitmap.width, bitmap.height)
      }
      const ctx = this.canvas.getContext('2d')
      if (!ctx) return
      ctx.clearRect(0, 0, bitmap.width, bitmap.height)
      ctx.drawImage(bitmap, 0, 0)
      const blob = await this.canvas.convertToBlob({ type: 'image/png' })
      await cache.put(
        keyUrl(key),
        new Response(blob, { headers: { 'Content-Type': 'image/png' } }),
      )
      this.absent.delete(key)
    } catch {
      // Storage full, evicted, or unavailable. The tile stays in memory.
    } finally {
      this.writing.delete(key)
    }
  }

  /** Drop everything. Used when the stored format changes. */
  async clear(): Promise<void> {
    try {
      await caches.delete(CACHE_NAME)
    } catch {
      /* nothing to do */
    }
    this.cache = null
    this.opening = null
    this.absent.clear()
  }
}
