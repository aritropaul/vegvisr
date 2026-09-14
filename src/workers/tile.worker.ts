/// <reference lib="webworker" />
import init, {
  World,
  location_table as locationTable,
  search_batch as searchBatch,
} from '../wasm/worldgen.js'
import { tileOrigin, tileSpan, type Req, type Res } from '../core/protocol'

type WasmExports = { memory: WebAssembly.Memory }

let wasm: WasmExports | null = null
let world: World | null = null
let booting: Promise<void> | null = null

async function ensureRuntime() {
  if (!booting) {
    booting = init().then((exports) => {
      wasm = exports as unknown as WasmExports
    })
  }
  await booting
}

const post = (res: Res, transfer?: Transferable[]) =>
  (self as unknown as Worker).postMessage(res, transfer ?? [])

self.onmessage = async (e: MessageEvent<Req>) => {
  const msg = e.data
  await ensureRuntime()

  if (msg.type === 'search') {
    // Search builds its own generator per candidate, so it does not touch the
    // worker's World and can run before one exists.
    const hits = searchBatch(
      msg.start, msg.count, msg.radius, msg.nearMask, msg.minHomeKm2, msg.homeMask,
    )
    post({ type: 'search', start: msg.start, count: msg.count, hits })
    return
  }

  if (msg.type === 'init') {
    const t0 = performance.now()
    world?.free()
    world = new World(msg.seedName, msg.worldGenVersion)
    post({ type: 'ready', seed: world.seed, ms: performance.now() - t0 })
    return
  }

  if (!world || !wasm) return

  if (msg.type === 'terrain') {
    const heights = world.heights_grid(msg.ox, msg.oy, msg.span, msg.grid, msg.grid)
    const ptr = world.render_tile(msg.ox, msg.oy, msg.span, msg.tex, msg.mode, msg.palette)
    const view = new Uint8ClampedArray(wasm.memory.buffer, ptr, msg.tex * msg.tex * 4)
    const img = new ImageData(new Uint8ClampedArray(view), msg.tex, msg.tex)
    const bitmap = await createImageBitmap(img)
    post(
      { type: 'terrain', id: msg.id, heights, grid: msg.grid, span: msg.span, bitmap },
      [heights.buffer, bitmap],
    )
    return
  }

  if (msg.type === 'locations') {
    // Placement is ~20 s of rejection sampling across 183 types. Run it in
    // slices so the page can show progress, and push an early snapshot once
    // the prioritised types are down — that slice holds every boss, trader
    // and the start temple, which is what the map is mostly used to find.
    let progress = 0
    let sentEarly = false
    while (progress < 1) {
      progress = world.locations_step(8)
      const milestone = !sentEarly && progress >= 0.12
      if (milestone) sentEarly = true
      const data = milestone ? world.locations_snapshot() : undefined
      post(
        { type: 'locProgress', id: msg.id, progress, data, table: data ? locationTable() : undefined },
        data ? [data.buffer] : [],
      )
    }
    const data = world.locations_snapshot()
    // report() reuses the placement and connectivity the loop just built,
    // so asking for it here costs nothing extra.
    const report = world.report()
    post({ type: 'locations', id: msg.id, data, table: locationTable(), report }, [data.buffer])
    return
  }

  if (msg.type === 'hist') {
    post({
      type: 'hist',
      id: msg.id,
      counts: world.biome_histogram(msg.ox, msg.oy, msg.spanX, msg.spanY, msg.n),
    })
    return
  }

  if (msg.type === 'query') {
    post({
      type: 'query',
      id: msg.id,
      biome: world.biome_at(msg.wx, msg.wy),
      height: world.height_at(msg.wx, msg.wy),
    })
    return
  }

  const t0 = performance.now()
  const [ox, oy] = tileOrigin(msg.z, msg.x, msg.y)
  const ptr = world.render_tile(ox, oy, tileSpan(msg.z), msg.size, msg.mode, msg.palette)

  // Re-derive the view on every call. Any wasm memory growth replaces the
  // backing ArrayBuffer and detaches previously created views.
  const len = msg.size * msg.size * 4
  const view = new Uint8ClampedArray(wasm.memory.buffer, ptr, len)
  // One copy out of wasm memory, because the renderer reuses that buffer for
  // the next tile. ImageData then adopts the copy without copying again.
  const img = new ImageData(new Uint8ClampedArray(view), msg.size, msg.size)

  const bitmap = await createImageBitmap(img)
  post({ type: 'tile', id: msg.id, bitmap, ms: performance.now() - t0 }, [bitmap])
}
