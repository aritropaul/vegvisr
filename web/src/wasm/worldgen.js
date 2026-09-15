/* @ts-self-types="./worldgen.d.ts" */

export class World {
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        WorldFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_world_free(ptr, 0);
    }
    /**
     * Biome id at a world position (raw enum value).
     * @param {number} wx
     * @param {number} wy
     * @returns {number}
     */
    biome_at(wx, wy) {
        const ret = wasm.world_biome_at(this.__wbg_ptr, wx, wy);
        return ret;
    }
    /**
     * Biome counts over a sampled lattice, indexed by biome ordinal.
     * Samples outside the 10km playable disc are skipped — beyond it the
     * generator still classifies terrain (as Ashlands, mostly), which would
     * swamp the composition readout with area no player can reach.
     * @param {number} ox
     * @param {number} oy
     * @param {number} span_x
     * @param {number} span_y
     * @param {number} n
     * @returns {Uint32Array}
     */
    biome_histogram(ox, oy, span_x, span_y, n) {
        const ret = wasm.world_biome_histogram(this.__wbg_ptr, ox, oy, span_x, span_y, n);
        var v1 = getArrayU32FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Terrain height at a world position, in world Y units (sea level = 30).
     * @param {number} wx
     * @param {number} wy
     * @returns {number}
     */
    height_at(wx, wy) {
        const ret = wasm.world_height_at(this.__wbg_ptr, wx, wy);
        return ret;
    }
    /**
     * Heights over an `nx` x `ny` lattice, row-major from the NORTH edge
     * southward. One call instead of n*m boundary crossings.
     * @param {number} ox
     * @param {number} oy
     * @param {number} span
     * @param {number} nx
     * @param {number} ny
     * @returns {Float32Array}
     */
    heights_grid(ox, oy, span, nx, ny) {
        const ret = wasm.world_heights_grid(this.__wbg_ptr, ox, oy, span, nx, ny);
        var v1 = getArrayF32FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Per-category counts, so the UI can show totals for categories it has
     * not fetched. 15 numbers instead of 12 000 records.
     * @returns {Uint32Array}
     */
    location_counts() {
        const ret = wasm.world_location_counts(this.__wbg_ptr);
        var v1 = getArrayU32FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
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
     * @param {number} kind_mask
     * @returns {Float32Array}
     */
    locations_of(kind_mask) {
        const ret = wasm.world_locations_of(this.__wbg_ptr, kind_mask);
        var v1 = getArrayF32FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Everything placed so far, in the same layout as `locations()`.
     * @param {number} kind_mask
     * @returns {Float32Array}
     */
    locations_snapshot(kind_mask) {
        const ret = wasm.world_locations_snapshot(this.__wbg_ptr, kind_mask);
        var v1 = getArrayF32FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Places the next `types` location types and returns progress in 0..1.
     * Placement is strictly sequential — one shared occupancy map, prioritised
     * types first — so this is the only honest way to report progress on it.
     * Prioritised types (every boss, trader and the start temple) come first,
     * so the markers people navigate by land in the first couple of steps.
     * @param {number} types
     * @returns {number}
     */
    locations_step(types) {
        const ret = wasm.world_locations_step(this.__wbg_ptr, types);
        return ret;
    }
    /**
     * Builds the world and runs the one-time lake/river/stream pregeneration.
     * @param {string} seed_name
     * @param {number} world_gen_version
     */
    constructor(seed_name, world_gen_version) {
        const ptr0 = passStringToWasm0(seed_name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.world_new(ptr0, len0, world_gen_version);
        this.__wbg_ptr = ret;
        WorldFinalization.register(this, this.__wbg_ptr, this);
        return this;
    }
    /**
     * Rasterises a tile into wasm memory and returns the byte offset.
     * The caller builds a Uint8ClampedArray view over `memory.buffer` at this
     * pointer — re-derive it after every call, since growth detaches views.
     * @param {number} ox
     * @param {number} oy
     * @param {number} span
     * @param {number} size
     * @param {number} mode
     * @param {number} palette
     * @returns {number}
     */
    render_tile(ox, oy, span, size, mode, palette) {
        const ret = wasm.world_render_tile(this.__wbg_ptr, ox, oy, span, size, mode, palette);
        return ret >>> 0;
    }
    /**
     * The headline facts people actually quote when they share a seed, as
     * JSON: how big the starting landmass is, and for each boss and trader
     * the nearest instance plus whether you can walk to it.
     * @returns {string}
     */
    report() {
        let deferred1_0;
        let deferred1_1;
        try {
            const ret = wasm.world_report(this.__wbg_ptr);
            deferred1_0 = ret[0];
            deferred1_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
        }
    }
    /**
     * @returns {number}
     */
    get seed() {
        const ret = wasm.world_seed(this.__wbg_ptr);
        return ret;
    }
}
if (Symbol.dispose) World.prototype[Symbol.dispose] = World.prototype.free;

/**
 * Biome bit for a name, so the UI can build masks without hardcoding the
 * enum's discriminants in two languages.
 * @param {string} name
 * @returns {number}
 */
export function biome_bit(name) {
    const ptr0 = passStringToWasm0(name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    const ret = wasm.biome_bit(ptr0, len0);
    return ret;
}

/**
 * The location config table as JSON, so the UI can label markers without
 * duplicating the table.
 * @returns {string}
 */
export function location_table() {
    let deferred1_0;
    let deferred1_1;
    try {
        const ret = wasm.location_table();
        deferred1_0 = ret[0];
        deferred1_1 = ret[1];
        return getStringFromWasm0(ret[0], ret[1]);
    } finally {
        wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
    }
}

/**
 * Scans a batch of candidate seeds against the given criteria and returns the
 * hits as JSON. Batched so the worker can report progress and stay
 * interruptible without the search holding a lock on the whole run.
 * @param {number} start
 * @param {number} count
 * @param {number} radius
 * @param {number} near_mask
 * @param {number} min_home_km2
 * @param {number} home_mask
 * @returns {string}
 */
export function search_batch(start, count, radius, near_mask, min_home_km2, home_mask) {
    let deferred1_0;
    let deferred1_1;
    try {
        const ret = wasm.search_batch(start, count, radius, near_mask, min_home_km2, home_mask);
        deferred1_0 = ret[0];
        deferred1_1 = ret[1];
        return getStringFromWasm0(ret[0], ret[1]);
    } finally {
        wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
    }
}

/**
 * Seed phrase -> integer world seed, exposed for the UI.
 * @param {string} name
 * @returns {number}
 */
export function seed_from_name(name) {
    const ptr0 = passStringToWasm0(name, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    const ret = wasm.seed_from_name(ptr0, len0);
    return ret;
}
function __wbg_get_imports() {
    const import0 = {
        __proto__: null,
        __wbg___wbindgen_throw_5d9e815e6fdf150f: function(arg0, arg1) {
            throw new Error(getStringFromWasm0(arg0, arg1));
        },
        __wbindgen_init_externref_table: function() {
            const table = wasm.__wbindgen_externrefs;
            const offset = table.grow(4);
            table.set(0, undefined);
            table.set(offset + 0, undefined);
            table.set(offset + 1, null);
            table.set(offset + 2, true);
            table.set(offset + 3, false);
        },
    };
    return {
        __proto__: null,
        "./worldgen_bg.js": import0,
    };
}

const WorldFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_world_free(ptr, 1));

function getArrayF32FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getFloat32ArrayMemory0().subarray(ptr / 4, ptr / 4 + len);
}

function getArrayU32FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getUint32ArrayMemory0().subarray(ptr / 4, ptr / 4 + len);
}

let cachedFloat32ArrayMemory0 = null;
function getFloat32ArrayMemory0() {
    if (cachedFloat32ArrayMemory0 === null || cachedFloat32ArrayMemory0.byteLength === 0) {
        cachedFloat32ArrayMemory0 = new Float32Array(wasm.memory.buffer);
    }
    return cachedFloat32ArrayMemory0;
}

function getStringFromWasm0(ptr, len) {
    return decodeText(ptr >>> 0, len);
}

let cachedUint32ArrayMemory0 = null;
function getUint32ArrayMemory0() {
    if (cachedUint32ArrayMemory0 === null || cachedUint32ArrayMemory0.byteLength === 0) {
        cachedUint32ArrayMemory0 = new Uint32Array(wasm.memory.buffer);
    }
    return cachedUint32ArrayMemory0;
}

let cachedUint8ArrayMemory0 = null;
function getUint8ArrayMemory0() {
    if (cachedUint8ArrayMemory0 === null || cachedUint8ArrayMemory0.byteLength === 0) {
        cachedUint8ArrayMemory0 = new Uint8Array(wasm.memory.buffer);
    }
    return cachedUint8ArrayMemory0;
}

function passStringToWasm0(arg, malloc, realloc) {
    if (realloc === undefined) {
        const buf = cachedTextEncoder.encode(arg);
        const ptr = malloc(buf.length, 1) >>> 0;
        getUint8ArrayMemory0().subarray(ptr, ptr + buf.length).set(buf);
        WASM_VECTOR_LEN = buf.length;
        return ptr;
    }

    let len = arg.length;
    let ptr = malloc(len, 1) >>> 0;

    const mem = getUint8ArrayMemory0();

    let offset = 0;

    for (; offset < len; offset++) {
        const code = arg.charCodeAt(offset);
        if (code > 0x7F) break;
        mem[ptr + offset] = code;
    }
    if (offset !== len) {
        if (offset !== 0) {
            arg = arg.slice(offset);
        }
        ptr = realloc(ptr, len, len = offset + arg.length * 3, 1) >>> 0;
        const view = getUint8ArrayMemory0().subarray(ptr + offset, ptr + len);
        const ret = cachedTextEncoder.encodeInto(arg, view);

        offset += ret.written;
        ptr = realloc(ptr, len, offset, 1) >>> 0;
    }

    WASM_VECTOR_LEN = offset;
    return ptr;
}

let cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
cachedTextDecoder.decode();
const MAX_SAFARI_DECODE_BYTES = 2146435072;
let numBytesDecoded = 0;
function decodeText(ptr, len) {
    numBytesDecoded += len;
    if (numBytesDecoded >= MAX_SAFARI_DECODE_BYTES) {
        cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
        cachedTextDecoder.decode();
        numBytesDecoded = len;
    }
    return cachedTextDecoder.decode(getUint8ArrayMemory0().subarray(ptr, ptr + len));
}

const cachedTextEncoder = new TextEncoder();

if (!('encodeInto' in cachedTextEncoder)) {
    cachedTextEncoder.encodeInto = function (arg, view) {
        const buf = cachedTextEncoder.encode(arg);
        view.set(buf);
        return {
            read: arg.length,
            written: buf.length
        };
    };
}

let WASM_VECTOR_LEN = 0;

let wasmModule, wasmInstance, wasm;
function __wbg_finalize_init(instance, module) {
    wasmInstance = instance;
    wasm = instance.exports;
    wasmModule = module;
    cachedFloat32ArrayMemory0 = null;
    cachedUint32ArrayMemory0 = null;
    cachedUint8ArrayMemory0 = null;
    wasm.__wbindgen_start();
    return wasm;
}

async function __wbg_load(module, imports) {
    if (typeof Response === 'function' && module instanceof Response) {
        if (!module.ok) {
            throw new Error(`failed to fetch Wasm: ${module.status} ${module.statusText} fetching '${module.url}'`);
        }

        if (typeof WebAssembly.instantiateStreaming === 'function') {
            try {
                return await WebAssembly.instantiateStreaming(module, imports);
            } catch (e) {
                const validResponse = expectedResponseType(module.type);

                if (validResponse && module.headers.get('Content-Type') !== 'application/wasm') {
                    console.warn("`WebAssembly.instantiateStreaming` failed because your server does not serve Wasm with `application/wasm` MIME type. Falling back to `WebAssembly.instantiate` which is slower. Original error:\n", e);

                } else { throw e; }
            }
        }

        const bytes = await module.arrayBuffer();
        return await WebAssembly.instantiate(bytes, imports);
    } else {
        const instance = await WebAssembly.instantiate(module, imports);

        if (instance instanceof WebAssembly.Instance) {
            return { instance, module };
        } else {
            return instance;
        }
    }

    function expectedResponseType(type) {
        switch (type) {
            case 'basic': case 'cors': case 'default': return true;
        }
        return false;
    }
}

function initSync(module) {
    if (wasm !== undefined) return wasm;


    if (module !== undefined) {
        if (Object.getPrototypeOf(module) === Object.prototype) {
            ({module} = module)
        } else {
            console.warn('using deprecated parameters for `initSync()`; pass a single object instead')
        }
    }

    const imports = __wbg_get_imports();
    if (!(module instanceof WebAssembly.Module)) {
        module = new WebAssembly.Module(module);
    }
    const instance = new WebAssembly.Instance(module, imports);
    return __wbg_finalize_init(instance, module);
}

async function __wbg_init(module_or_path) {
    if (wasm !== undefined) return wasm;


    if (module_or_path !== undefined) {
        if (Object.getPrototypeOf(module_or_path) === Object.prototype) {
            ({module_or_path} = module_or_path)
        } else {
            console.warn('using deprecated parameters for the initialization function; pass a single object instead')
        }
    }

    if (module_or_path === undefined) {
        module_or_path = new URL('worldgen_bg.wasm', import.meta.url);
    }
    const imports = __wbg_get_imports();

    if (typeof module_or_path === 'string' || (typeof Request === 'function' && module_or_path instanceof Request) || (typeof URL === 'function' && module_or_path instanceof URL)) {
        module_or_path = fetch(module_or_path);
    }

    const { instance, module } = await __wbg_load(await module_or_path, imports);

    return __wbg_finalize_init(instance, module);
}

export { initSync, __wbg_init as default };
