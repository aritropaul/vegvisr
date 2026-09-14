/* tslint:disable */
/* eslint-disable */

export class World {
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Biome id at a world position (raw enum value).
     */
    biome_at(wx: number, wy: number): number;
    /**
     * Biome counts over a sampled lattice, indexed by biome ordinal.
     * Samples outside the 10km playable disc are skipped — beyond it the
     * generator still classifies terrain (as Ashlands, mostly), which would
     * swamp the composition readout with area no player can reach.
     */
    biome_histogram(ox: number, oy: number, span_x: number, span_y: number, n: number): Uint32Array;
    /**
     * Terrain height at a world position, in world Y units (sea level = 30).
     */
    height_at(wx: number, wy: number): number;
    /**
     * Heights over an `nx` x `ny` lattice, row-major from the NORTH edge
     * southward. One call instead of n*m boundary crossings.
     */
    heights_grid(ox: number, oy: number, span: number, nx: number, ny: number): Float32Array;
    /**
     * Per-category counts, so the UI can show totals for categories it has
     * not fetched. 15 numbers instead of 12 000 records.
     */
    location_counts(): Uint32Array;
    /**
     * Placed locations whose `Kind` is set in `kind_mask`, flattened as
     * [kind, cfgIndex, x, y, reachable] per entry. `reachable` is 1 when the
     * site shares the spawn landmass.
     *
     * Filtering here rather than in JS matters: a world holds ~12 000 sites
     * but only a few hundred are ever switched on, and shipping the rest
     * across the boundary costs a 240 KB copy plus the spatial index built
     * over it. Placement itself still runs for every type — it cannot be
     * filtered, because all types compete for the same 64 m zones and
     * skipping one moves every location placed after it.
     */
    locations_of(kind_mask: number): Float32Array;
    /**
     * Everything placed so far, in the same layout as `locations()`.
     */
    locations_snapshot(kind_mask: number): Float32Array;
    /**
     * Places the next `types` location types and returns progress in 0..1.
     * Placement is strictly sequential — one shared occupancy map, prioritised
     * types first — so this is the only honest way to report progress on it.
     * Prioritised types (every boss, trader and the start temple) come first,
     * so the markers people navigate by land in the first couple of steps.
     */
    locations_step(types: number): number;
    /**
     * Builds the world and runs the one-time lake/river/stream pregeneration.
     */
    constructor(seed_name: string, world_gen_version: number);
    /**
     * Rasterises a tile into wasm memory and returns the byte offset.
     * The caller builds a Uint8ClampedArray view over `memory.buffer` at this
     * pointer — re-derive it after every call, since growth detaches views.
     */
    render_tile(ox: number, oy: number, span: number, size: number, mode: number, palette: number): number;
    /**
     * The headline facts people actually quote when they share a seed, as
     * JSON: how big the starting landmass is, and for each boss and trader
     * the nearest instance plus whether you can walk to it.
     */
    report(): string;
    readonly seed: number;
}

/**
 * Biome bit for a name, so the UI can build masks without hardcoding the
 * enum's discriminants in two languages.
 */
export function biome_bit(name: string): number;

/**
 * The location config table as JSON, so the UI can label markers without
 * duplicating the table.
 */
export function location_table(): string;

/**
 * Scans a batch of candidate seeds against the given criteria and returns the
 * hits as JSON. Batched so the worker can report progress and stay
 * interruptible without the search holding a lock on the whole run.
 */
export function search_batch(start: number, count: number, radius: number, near_mask: number, min_home_km2: number, home_mask: number): string;

/**
 * Seed phrase -> integer world seed, exposed for the UI.
 */
export function seed_from_name(name: string): number;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_world_free: (a: number, b: number) => void;
    readonly biome_bit: (a: number, b: number) => number;
    readonly location_table: () => [number, number];
    readonly search_batch: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number];
    readonly seed_from_name: (a: number, b: number) => number;
    readonly world_biome_at: (a: number, b: number, c: number) => number;
    readonly world_biome_histogram: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number];
    readonly world_height_at: (a: number, b: number, c: number) => number;
    readonly world_heights_grid: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number];
    readonly world_location_counts: (a: number) => [number, number];
    readonly world_locations_of: (a: number, b: number) => [number, number];
    readonly world_locations_snapshot: (a: number, b: number) => [number, number];
    readonly world_locations_step: (a: number, b: number) => number;
    readonly world_new: (a: number, b: number, c: number) => number;
    readonly world_render_tile: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => number;
    readonly world_report: (a: number) => [number, number];
    readonly world_seed: (a: number) => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
