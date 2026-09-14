/** LRU cache of rendered tiles, budgeted by decoded byte size. */
export class TileCache {
  private map = new Map<string, ImageBitmap>()
  private bytes = 0

  constructor(private maxBytes = 256 * 1024 * 1024) {}

  private sizeOf(b: ImageBitmap) {
    return b.width * b.height * 4
  }

  get(key: string): ImageBitmap | undefined {
    const v = this.map.get(key)
    if (!v) return undefined
    // Refresh recency; Map preserves insertion order.
    this.map.delete(key)
    this.map.set(key, v)
    return v
  }

  has(key: string) {
    return this.map.has(key)
  }

  set(key: string, bitmap: ImageBitmap) {
    const existing = this.map.get(key)
    if (existing) {
      this.bytes -= this.sizeOf(existing)
      // Guard against self-replacement: the pool hands the same ImageBitmap
      // to every deduplicated caller, so closing here would destroy the very
      // bitmap we are about to store.
      if (existing !== bitmap) existing.close()
      this.map.delete(key)
    }
    this.map.set(key, bitmap)
    this.bytes += this.sizeOf(bitmap)
    while (this.bytes > this.maxBytes && this.map.size > 1) {
      const oldest = this.map.keys().next().value as string
      const b = this.map.get(oldest)!
      this.bytes -= this.sizeOf(b)
      // Release the backing memory now rather than waiting for GC.
      b.close()
      this.map.delete(oldest)
    }
  }

  clear() {
    for (const b of this.map.values()) b.close()
    this.map.clear()
    this.bytes = 0
  }

  get count() {
    return this.map.size
  }

  get megabytes() {
    return this.bytes / (1024 * 1024)
  }
}
