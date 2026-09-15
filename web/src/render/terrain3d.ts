/**
 * Minimal WebGL2 terrain renderer for the 3D view.
 *
 * Hand-rolled rather than pulling in a scene graph: the whole job is one
 * displaced grid with one texture, and a 3D library would outweigh the entire
 * rest of the bundle.
 *
 * The mesh clamps terrain to sea level so the ocean renders as a flat plane
 * with land rising out of it, the way a physical relief model reads. Colour
 * comes from the same tile renderer the 2D map uses, so all three render
 * modes carry straight over.
 *
 * Detail is a **nested clipmap**, not a single patch. An earlier version
 * loaded one patch and swapped it for a tighter one as you zoomed, which meant
 * zooming in deleted the rest of the world: you flew around a floating square.
 * Raising the resolution of that one patch cannot fix it either — covering
 * 21 km at 2 m per vertex is 100 M vertices.
 *
 * So the surface is drawn as a stack of levels sharing one centre. The
 * coarsest spans the whole world; each finer level halves the span at the same
 * vertex count, doubling resolution, and every level except the finest is
 * drawn as a ring with its middle removed so levels never overlap. The result
 * is constant screen-space triangle density: the whole map is always on
 * screen, and the ground under the camera is always fine.
 */

import { WATER_LEVEL, WORLD_SPAN } from '../core/protocol'

const VERT = `#version 300 es
in vec3 aPos;
in vec3 aNrm;
in vec2 aUv;
uniform mat4 uMVP;
out vec3 vNrm;
out vec2 vUv;
out float vWet;
void main() {
  gl_Position = uMVP * vec4(aPos, 1.0);
  vNrm = aNrm;
  vUv = aUv;
  vWet = aPos.y <= 0.001 ? 1.0 : 0.0;
}`

const FRAG = `#version 300 es
precision highp float;
in vec3 vNrm;
in vec2 vUv;
in float vWet;
uniform sampler2D uTex;
uniform vec3 uLight;
out vec4 frag;
void main() {
  vec3 base = texture(uTex, vUv).rgb;
  vec3 n = normalize(vNrm);
  float key = max(dot(n, normalize(uLight)), 0.0);
  float fill = max(dot(n, normalize(vec3(-uLight.x, uLight.y * 0.4, -uLight.z))), 0.0);
  // Flat water needs no shading; land carries the light.
  float lit = mix(0.42 + key * 0.72 + fill * 0.18, 1.0, vWet * 0.82);
  frag = vec4(base * lit, 1.0);
}`

function compile(gl: WebGL2RenderingContext, type: number, src: string) {
  const sh = gl.createShader(type)!
  gl.shaderSource(sh, src)
  gl.compileShader(sh)
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(sh) ?? 'shader compile failed')
  }
  return sh
}

/** Column-major 4x4 helpers, just enough for one camera. */
function perspective(fovy: number, aspect: number, near: number, far: number): Float32Array {
  const f = 1 / Math.tan(fovy / 2)
  const m = new Float32Array(16)
  m[0] = f / aspect
  m[5] = f
  m[10] = (far + near) / (near - far)
  m[11] = -1
  m[14] = (2 * far * near) / (near - far)
  return m
}

function lookAt(eye: number[], target: number[], up: number[]): Float32Array {
  const z = norm(sub(eye, target))
  const x = norm(cross(up, z))
  const y = cross(z, x)
  const m = new Float32Array(16)
  m[0] = x[0]; m[4] = x[1]; m[8] = x[2]; m[12] = -dot(x, eye)
  m[1] = y[0]; m[5] = y[1]; m[9] = y[2]; m[13] = -dot(y, eye)
  m[2] = z[0]; m[6] = z[1]; m[10] = z[2]; m[14] = -dot(z, eye)
  m[15] = 1
  return m
}

const sub = (a: number[], b: number[]) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
const dot = (a: number[], b: number[]) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
const cross = (a: number[], b: number[]) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
]
function norm(v: number[]) {
  const l = Math.hypot(v[0], v[1], v[2]) || 1
  return [v[0] / l, v[1] / l, v[2] / l]
}

function mul(a: Float32Array, b: Float32Array): Float32Array {
  const o = new Float32Array(16)
  for (let c = 0; c < 4; c++) {
    for (let r = 0; r < 4; r++) {
      let sum = 0
      for (let k = 0; k < 4; k++) sum += a[k * 4 + r] * b[c * 4 + k]
      o[c * 4 + r] = sum
    }
  }
  return o
}

/** One ring of the clipmap. */
interface Level {
  vao: WebGLVertexArrayObject | null
  tex: WebGLTexture
  indexCount: number
  idxType: number
  /** World-space extent and centre, kept for picking and for reload decisions. */
  span: number
  cx: number
  cy: number
  grid: number
  heights: Float32Array
}

export class Terrain3D {
  private gl: WebGL2RenderingContext
  private prog: WebGLProgram
  private levels: Level[] = []
  private tex: WebGLTexture
  private indexCount = 0
  private raf = 0
  private dirty = true

  /** Free camera: orbit + horizontal translation of the look-at point. */
  yaw = -0.6
  pitch = 0.62
  dist = 1.6
  /** Look-at point on the ground plane, in normalised mesh space. */
  target: [number, number, number] = [0, 0, 0]
  /** Vertical exaggeration; Valheim terrain is gentle and reads flat at 1:1. */
  exaggeration = 2.6

  private dragging = false
  private last: [number, number] | null = null
  private spanWorld = 1
  private centre: [number, number] = [0, 0]
  private mvp: Float32Array = new Float32Array(16)
  /** Called after each frame so callers can overlay 2D symbology. */
  onFrame?: () => void

  constructor(private canvas: HTMLCanvasElement) {
    const gl = canvas.getContext('webgl2', { antialias: true, alpha: false })
    if (!gl) throw new Error('WebGL2 unavailable')
    this.gl = gl

    const prog = gl.createProgram()!
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT))
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG))
    gl.linkProgram(prog)
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
      throw new Error(gl.getProgramInfoLog(prog) ?? 'link failed')
    }
    this.prog = prog

    this.tex = gl.createTexture()!
    gl.bindTexture(gl.TEXTURE_2D, this.tex)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    // Anisotropic filtering matters enormously here: at a near-horizontal
    // camera the ground is sampled at extreme grazing angles, where plain
    // mipmapping collapses detail into mush.
    const aniso =
      gl.getExtension('EXT_texture_filter_anisotropic') ??
      gl.getExtension('WEBKIT_EXT_texture_filter_anisotropic')
    if (aniso) {
      const max = gl.getParameter(aniso.MAX_TEXTURE_MAX_ANISOTROPY_EXT) as number
      gl.texParameterf(gl.TEXTURE_2D, aniso.TEXTURE_MAX_ANISOTROPY_EXT, Math.min(16, max))
    }

    gl.enable(gl.DEPTH_TEST)
    gl.clearColor(0.016, 0.027, 0.055, 1)

    this.bindInput()
    this.loop()
  }

  /** Ground-plane basis for the current heading. */
  private basis(): { fwd: [number, number, number]; right: [number, number, number] } {
    const fwd: [number, number, number] = [-Math.sin(this.yaw), 0, -Math.cos(this.yaw)]
    // right = fwd x up
    const right: [number, number, number] = [-fwd[2], 0, fwd[0]]
    return { fwd, right }
  }

  /** Translate the look-at point across the ground plane. */
  panBy(dxScreen: number, dyScreen: number) {
    const { fwd, right } = this.basis()
    // Scale with distance so panning feels the same at any altitude.
    const k = this.dist * 0.0022
    for (let i = 0; i < 3; i++) {
      this.target[i] += right[i] * -dxScreen * k + fwd[i] * -dyScreen * k
    }
    // Stay within the loaded patch (the mesh spans -1..1).
    this.target[0] = Math.max(-1.4, Math.min(1.4, this.target[0]))
    this.target[2] = Math.max(-1.4, Math.min(1.4, this.target[2]))
    this.dirty = true
  }

  recentre() {
    this.target = [0, 0, 0]
    this.dirty = true
  }

  /** Frame the whole world. Called when the 3D view opens, because the camera
   *  persists between visits and a previous session's dolly can leave it
   *  buried in the surface with nothing on screen. */
  frameWorld() {
    this.target = [0, 0, 0]
    this.dist = 1.6
    this.yaw = 0
    this.pitch = 0.62
    this.dirty = true
  }

  /** World position of the current look-at point.
   *  Mesh space is pinned to the world, not to whichever level is loaded, so
   *  this stays correct even before any level has arrived. */
  targetWorld(): [number, number] {
    const s = 2 / WORLD_SPAN
    return [this.target[0] / s, -this.target[2] / s]
  }

  get span(): number {
    return this.spanWorld
  }

  /**
   * Ask the host for a fresh patch when the view has drifted far enough that
   * the current one is either too coarse (zoomed in) or wastefully tight
   * (zoomed out). Debounced so a continuous gesture only triggers one reload.
   */
  private requestDetail() {
    clearTimeout(this.detailTimer)
    this.detailTimer = window.setTimeout(() => {
      const [wx, wy] = this.targetWorld()
      // Roughly how much world the camera can see, in metres.
      const want = Math.max(400, Math.min(WORLD_SPAN * this.dist, WORLD_SPAN))
      const fine = this.levels[this.levels.length - 1]
      if (fine) {
        // Only reload when the camera has actually outgrown the finest ring:
        // either the visible span has changed by more than a factor of ~1.6,
        // or the look-at point has wandered past a quarter of that ring.
        const ratio = want / fine.span
        const drift = Math.hypot(wx - fine.cx, wy - fine.cy)
        if (ratio > 0.62 && ratio < 1.6 && drift < fine.span * 0.25) return
      }
      this.onNeedDetail?.(wx, wy, want)
    }, 280)
  }

  /** Bilinear height lookup in mesh space, clamped at sea level like the mesh. */
  private sampleMesh(x: number, z: number): number | null {
    // Walk finest-first so a hit lands on the sharpest lattice that covers it.
    for (let i = this.levels.length - 1; i >= 0; i--) {
      const lv = this.levels[i]
      if (!lv) continue
      const h = this.sampleLevel(lv, x, z)
      if (h !== null) return h
    }
    return null
  }

  private sampleLevel(lv: Level, x: number, z: number): number | null {
    const s = 2 / WORLD_SPAN
    const g = lv.grid
    // Mesh space -> this level's lattice space.
    const u = ((x / s - lv.cx) / lv.span + 0.5) * (g - 1)
    const v = ((-z / s - lv.cy) / lv.span + 0.5) * (g - 1)
    if (!(u >= 0 && v >= 0 && u <= g - 1 && v <= g - 1)) return null
    const i0 = Math.floor(u)
    const j0 = Math.floor(v)
    const i1 = Math.min(i0 + 1, g - 1)
    const j1 = Math.min(j0 + 1, g - 1)
    const fx = u - i0
    const fy = v - j0
    const at = (i: number, j: number) => Math.max(lv.heights[j * g + i] - WATER_LEVEL, 0)
    const h =
      at(i0, j0) * (1 - fx) * (1 - fy) +
      at(i1, j0) * fx * (1 - fy) +
      at(i0, j1) * (1 - fx) * fy +
      at(i1, j1) * fx * fy
    return h * this.exaggeration * s
  }

  private sampleMeshLegacy(x: number, z: number): number | null {
    if (!this.heights) return null
    const g = this.grid
    const s = 2 / this.spanWorld
    // Mesh x spans -1..1 across the patch; map back to lattice indices.
    const fi = ((x / s + this.spanWorld / 2) / this.spanWorld) * (g - 1)
    const fj = ((z / s + this.spanWorld / 2) / this.spanWorld) * (g - 1)
    if (fi < 0 || fj < 0 || fi > g - 1 || fj > g - 1) return null
    const i0 = Math.floor(fi)
    const j0 = Math.floor(fj)
    const i1 = Math.min(i0 + 1, g - 1)
    const j1 = Math.min(j0 + 1, g - 1)
    const tx = fi - i0
    const tz = fj - j0
    const at = (i: number, j: number) => Math.max(this.heights![j * g + i] - WATER_LEVEL, 0)
    const a = at(i0, j0) + (at(i1, j0) - at(i0, j0)) * tx
    const b = at(i0, j1) + (at(i1, j1) - at(i0, j1)) * tx
    return (a + (b - a) * tz) * this.exaggeration * s
  }

  /**
   * Raycasts the pointer against the height field. Marches coarsely until the
   * ray drops below the surface, then bisects — cheap and robust for a
   * heightfield, and avoids needing a depth readback from the GPU.
   */
  pick(sx: number, sy: number): { wx: number; wy: number; height: number } | null {
    if (!this.heights) return null
    const r = this.canvas.getBoundingClientRect()
    const ndcX = (sx / r.width) * 2 - 1
    const ndcY = 1 - (sy / r.height) * 2

    const cp = Math.cos(this.pitch)
    const t = this.target
    const eye = [
      t[0] + Math.sin(this.yaw) * cp * this.dist * 2.2,
      t[1] + Math.sin(this.pitch) * this.dist * 2.2,
      t[2] + Math.cos(this.yaw) * cp * this.dist * 2.2,
    ]
    const fwd = norm(sub(t as number[], eye))
    const right = norm(cross(fwd, [0, 1, 0]))
    const up = cross(right, fwd)
    const tanF = Math.tan((42 * Math.PI) / 180 / 2)
    const aspect = r.width / r.height
    const dir = norm([
      fwd[0] + right[0] * ndcX * aspect * tanF + up[0] * ndcY * tanF,
      fwd[1] + right[1] * ndcX * aspect * tanF + up[1] * ndcY * tanF,
      fwd[2] + right[2] * ndcX * aspect * tanF + up[2] * ndcY * tanF,
    ])

    const step = 0.008
    const maxT = 12
    let prev = 0
    let prevAbove = true
    for (let d = 0.02; d < maxT; d += step) {
      const px = eye[0] + dir[0] * d
      const py = eye[1] + dir[1] * d
      const pz = eye[2] + dir[2] * d
      const surf = this.sampleMesh(px, pz)
      if (surf === null) {
        // Outside the patch: keep marching, it may re-enter.
        prev = d
        continue
      }
      const above = py > surf
      if (!above && prevAbove) {
        // Bisect between the last above-surface sample and this one.
        let lo = prev
        let hi = d
        for (let k = 0; k < 20; k++) {
          const mid = (lo + hi) / 2
          const my = eye[1] + dir[1] * mid
          const ms = this.sampleMesh(eye[0] + dir[0] * mid, eye[2] + dir[2] * mid)
          if (ms === null) break
          if (my > ms) lo = mid
          else hi = mid
        }
        const hitT = (lo + hi) / 2
        const hx = eye[0] + dir[0] * hitT
        const hz = eye[2] + dir[2] * hitT
        const sc = 2 / this.spanWorld
        return {
          wx: this.centre[0] + hx / sc,
          wy: this.centre[1] - hz / sc,
          height: 0,
        }
      }
      prevAbove = above
      prev = d
    }
    return null
  }

  private bindInput() {
    const el = this.canvas
    // Right-drag pans by default; suppress the context menu so it can.
    el.addEventListener('contextmenu', (e) => e.preventDefault())

    el.addEventListener('pointerdown', (e) => {
      el.setPointerCapture(e.pointerId)
      this.dragging = true
      this.panning = e.button === 2 || e.button === 1 || e.shiftKey
      this.last = [e.clientX, e.clientY]
    })
    el.addEventListener('pointermove', (e) => {
      if (!this.dragging) {
        const r = el.getBoundingClientRect()
        const hit = this.pick(e.clientX - r.left, e.clientY - r.top)
        if (hit) this.onPick?.(hit.wx, hit.wy, hit.height)
      }
      if (!this.dragging || !this.last) return
      const dx = e.clientX - this.last[0]
      const dy = e.clientY - this.last[1]
      this.last = [e.clientX, e.clientY]
      if (this.panning) {
        this.panBy(dx, dy)
        this.requestDetail()
        return
      }
      this.yaw -= dx * 0.006
      // Down to the horizon, but never under the surface.
      this.pitch = Math.min(1.5, Math.max(0.015, this.pitch + dy * 0.005))
      this.dirty = true
    })
    const end = () => {
      this.dragging = false
      this.panning = false
      this.last = null
    }
    el.addEventListener('pointerup', end)
    el.addEventListener('pointercancel', end)
    el.addEventListener(
      'wheel',
      (e) => {
        e.preventDefault()
        if (e.shiftKey) {
          // Shift+wheel strafes rather than dollies.
          this.panBy(-e.deltaX || 0, -e.deltaY)
          return
        }
        this.dist = Math.min(4.0, Math.max(0.18, this.dist * (1 + e.deltaY * 0.0012)))
        this.dirty = true
        this.requestDetail()
      },
      { passive: false },
    )

    // WASD / arrows fly the camera horizontally.
    this.onKey = (e: KeyboardEvent) => {
      if (!this.enabled) return
      const tag = (e.target as HTMLElement | null)?.tagName
      if (tag === 'INPUT' || tag === 'TEXTAREA') return
      const step = 26
      switch (e.key) {
        case 'ArrowUp': case 'w': case 'W': this.panBy(0, step); this.requestDetail(); break
        case 'ArrowDown': case 's': case 'S': this.panBy(0, -step); this.requestDetail(); break
        case 'ArrowLeft': case 'a': case 'A': this.panBy(step, 0); this.requestDetail(); break
        case 'ArrowRight': case 'd': case 'D': this.panBy(-step, 0); this.requestDetail(); break
        case 'q': case 'Q': this.dist = Math.min(4.0, this.dist * 1.08); this.dirty = true; this.requestDetail(); break
        case 'e': case 'E': this.dist = Math.max(0.18, this.dist / 1.08); this.dirty = true; this.requestDetail(); break
        case 'r': case 'R': this.recentre(); break
        default: return
      }
      e.preventDefault()
    }
    window.addEventListener('keydown', this.onKey)
  }

  /** Height lattice kept on the CPU so the pointer can be raycast against it. */
  private heights: Float32Array | null = null
  private grid = 0
  /** Fires with world coordinates under the pointer, or null off-surface. */
  onPick?: (wx: number, wy: number, height: number) => void
  /**
   * Fires (debounced) when the camera has moved or zoomed enough that the
   * loaded patch no longer matches the detail on screen. Without this, zooming
   * in just magnifies a fixed lattice and the terrain goes blocky.
   */
  onNeedDetail?: (centreX: number, centreY: number, span: number) => void
  private detailTimer = 0

  private panning = false
  private onKey: ((e: KeyboardEvent) => void) | null = null
  /** Set by the host so key handling only applies while the 3D view is shown. */
  enabled = true

  setExaggeration(v: number) {
    this.exaggeration = v
    this.dirty = true
  }

  /**
   * Installs one clipmap level. The hole is the footprint of the finer level
   * drawn inside this one — given as its own centre and half-extent, because
   * each level snaps to its own cell size and so they do *not* share a centre.
   * Punching the hole at this level's centre instead leaves a gap on one side
   * and a double-drawn strip on the other. Pass `holeHalf = 0` for the finest.
   *
   * All levels are built in one shared mesh space scaled by `WORLD_SPAN`, so
   * they line up regardless of their own span and the camera maths stays
   * independent of which levels happen to be loaded.
   */
  setLevel(
    index: number,
    heights: Float32Array,
    grid: number,
    span: number,
    cx: number,
    cy: number,
    holeCx: number,
    holeCy: number,
    holeHalf: number,
  ) {
    const gl = this.gl
    const s = 2 / WORLD_SPAN
    const step = span / (grid - 1)
    // Perimeter skirt: a curtain hanging from the outer edge. Adjacent levels
    // sample the same boundary at different resolutions, so their edges do not
    // agree to the last metre and hairline gaps show through to the
    // background. The skirt is hidden behind the surface from any normal
    // viewing angle and costs one extra ring of vertices.
    const skirtCount = grid * 4
    const verts = new Float32Array((grid * grid + skirtCount) * 8)

    for (let j = 0; j < grid; j++) {
      for (let i = 0; i < grid; i++) {
        const k = j * grid + i
        // Sea renders as a flat plane; land rises out of it.
        const h = Math.max(heights[k] - WATER_LEVEL, 0)

        // Central differences on the clamped field give matching normals.
        const hl = Math.max(heights[j * grid + Math.max(i - 1, 0)] - WATER_LEVEL, 0)
        const hr = Math.max(heights[j * grid + Math.min(i + 1, grid - 1)] - WATER_LEVEL, 0)
        const hd = Math.max(heights[Math.max(j - 1, 0) * grid + i] - WATER_LEVEL, 0)
        const hu = Math.max(heights[Math.min(j + 1, grid - 1) * grid + i] - WATER_LEVEL, 0)
        const nx = (hl - hr) * this.exaggeration * s
        const nz = (hd - hu) * this.exaggeration * s
        const ny = 2 * step * s
        const nl = Math.hypot(nx, ny, nz) || 1

        const wx = cx + (i * step - span / 2)
        const wy = cy + (j * step - span / 2)
        const o = k * 8
        verts[o] = wx * s
        verts[o + 1] = h * this.exaggeration * s
        verts[o + 2] = -wy * s
        verts[o + 3] = nx / nl
        verts[o + 4] = ny / nl
        verts[o + 5] = nz / nl
        verts[o + 6] = i / (grid - 1)
        verts[o + 7] = j / (grid - 1)
      }
    }

    const quads = (grid - 1) * (grid - 1) + grid * 4
    // Width is decided by the highest *vertex* index, not the triangle count —
    // the skirt ring sits above the grid, so a mesh can need 32-bit indices
    // while having comparatively few triangles.
    const wide = grid * grid + skirtCount > 65535
    const idx = wide ? new Uint32Array(quads * 6) : new Uint16Array(quads * 6)
    let p = 0
    for (let j = 0; j < grid - 1; j++) {
      for (let i = 0; i < grid - 1; i++) {
        if (holeHalf > 0) {
          // Drop the quad only when it lies wholly inside the finer level, so
          // one row of overlap remains along the seam. The overlap plus the
          // perimeter skirt below is what closes the crack where two
          // resolutions sample the same edge slightly differently.
          const x0 = cx + (i * step - span / 2)
          const x1 = x0 + step
          const y0 = cy + (j * step - span / 2)
          const y1 = y0 + step
          if (
            Math.max(Math.abs(x0 - holeCx), Math.abs(x1 - holeCx)) < holeHalf &&
            Math.max(Math.abs(y0 - holeCy), Math.abs(y1 - holeCy)) < holeHalf
          ) {
            continue
          }
        }
        const a = j * grid + i
        idx[p++] = a
        idx[p++] = a + grid
        idx[p++] = a + 1
        idx[p++] = a + 1
        idx[p++] = a + grid
        idx[p++] = a + grid + 1
      }
    }

    // Drop far enough to cover any plausible mismatch between two levels'
    // sampling of the same edge, scaled to this level's own cell size.
    const drop = step * 4 * this.exaggeration * s
    let sv = grid * grid
    const addSkirt = (i: number, j: number) => {
      const src = (j * grid + i) * 8
      const o = sv * 8
      verts[o] = verts[src]
      verts[o + 1] = verts[src + 1] - drop
      verts[o + 2] = verts[src + 2]
      verts[o + 3] = verts[src + 3]
      verts[o + 4] = verts[src + 4]
      verts[o + 5] = verts[src + 5]
      verts[o + 6] = verts[src + 6]
      verts[o + 7] = verts[src + 7]
      return sv++
    }
    const edges: Array<[number, number]> = []
    for (let i = 0; i < grid; i++) edges.push([i, 0])
    for (let j = 0; j < grid; j++) edges.push([grid - 1, j])
    for (let i = grid - 1; i >= 0; i--) edges.push([i, grid - 1])
    for (let j = grid - 1; j >= 0; j--) edges.push([0, j])
    const skirtIdx: number[] = []
    let prevTop = -1
    let prevBot = -1
    for (const [i, j] of edges) {
      const top = j * grid + i
      const bot = addSkirt(i, j)
      if (prevTop >= 0) {
        skirtIdx.push(prevTop, prevBot, top, top, prevBot, bot)
      }
      prevTop = top
      prevBot = bot
    }
    for (const v of skirtIdx) idx[p++] = v

    const prev = this.levels[index]
    if (prev?.vao) gl.deleteVertexArray(prev.vao)

    const vao = gl.createVertexArray()
    gl.bindVertexArray(vao)
    const vbo = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo)
    gl.bufferData(gl.ARRAY_BUFFER, verts, gl.STATIC_DRAW)
    const stride = 8 * 4
    for (const [loc, size, off] of [
      ['aPos', 3, 0],
      ['aNrm', 3, 12],
      ['aUv', 2, 24],
    ] as Array<[string, number, number]>) {
      const l = gl.getAttribLocation(this.prog, loc)
      gl.enableVertexAttribArray(l)
      gl.vertexAttribPointer(l, size, gl.FLOAT, false, stride, off)
    }
    const ebo = gl.createBuffer()
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo)
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, idx, gl.STATIC_DRAW)
    gl.bindVertexArray(null)

    this.levels[index] = {
      vao,
      tex: prev?.tex ?? this.newTexture(),
      indexCount: p,
      idxType: wide ? gl.UNSIGNED_INT : gl.UNSIGNED_SHORT,
      span,
      cx,
      cy,
      grid,
      heights,
    }
    // Keep the coarsest level's lattice for picking when nothing finer covers
    // the cursor.
    if (index === 0) {
      this.heights = heights
      this.grid = grid
      this.spanWorld = span
      this.centre = [cx, cy]
    }
    this.indexCount = this.levels.reduce((n, l) => n + (l?.indexCount ?? 0), 0)
    this.dirty = true
  }

  setLevelTexture(index: number, bitmap: ImageBitmap) {
    const gl = this.gl
    const lv = this.levels[index]
    if (!lv) return
    gl.bindTexture(gl.TEXTURE_2D, lv.tex)
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap)
    gl.generateMipmap(gl.TEXTURE_2D)
    gl.bindTexture(gl.TEXTURE_2D, null)
    bitmap.close()
    this.dirty = true
  }

  /** Drops every level above `count`, e.g. after zooming back out. */
  trimLevels(count: number) {
    const gl = this.gl
    for (let i = count; i < this.levels.length; i++) {
      const lv = this.levels[i]
      if (lv?.vao) gl.deleteVertexArray(lv.vao)
      if (lv?.tex) gl.deleteTexture(lv.tex)
    }
    if (this.levels.length > count) this.levels.length = count
    this.dirty = true
  }

  private newTexture(): WebGLTexture {
    const gl = this.gl
    const t = gl.createTexture()!
    gl.bindTexture(gl.TEXTURE_2D, t)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    const aniso =
      gl.getExtension('EXT_texture_filter_anisotropic') ??
      gl.getExtension('WEBKIT_EXT_texture_filter_anisotropic')
    if (aniso) {
      const max = gl.getParameter(aniso.MAX_TEXTURE_MAX_ANISOTROPY_EXT) as number
      gl.texParameterf(gl.TEXTURE_2D, aniso.TEXTURE_MAX_ANISOTROPY_EXT, Math.min(16, max))
    }
    gl.bindTexture(gl.TEXTURE_2D, null)
    return t
  }

  private idxType: number = 0x1403

  setTexture(bitmap: ImageBitmap) {
    const gl = this.gl
    gl.bindTexture(gl.TEXTURE_2D, this.tex)
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false)
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap)
    gl.generateMipmap(gl.TEXTURE_2D)
    bitmap.close()
    this.dirty = true
  }

  invalidate() {
    this.dirty = true
  }

  private loop = () => {
    this.raf = requestAnimationFrame(this.loop)
    if (!this.dirty) return
    this.dirty = false
    this.draw()
  }

  private draw() {
    const gl = this.gl
    const dpr = window.devicePixelRatio || 1
    const r = this.canvas.getBoundingClientRect()
    const w = Math.round(r.width * dpr)
    const h = Math.round(r.height * dpr)
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w
      this.canvas.height = h
    }
    gl.viewport(0, 0, w, h)
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
    if (!this.levels.length || !this.indexCount) return

    const cp = Math.cos(this.pitch)
    const t = this.target
    const eye = [
      t[0] + Math.sin(this.yaw) * cp * this.dist * 2.2,
      t[1] + Math.sin(this.pitch) * this.dist * 2.2,
      t[2] + Math.cos(this.yaw) * cp * this.dist * 2.2,
    ]
    const proj = perspective((42 * Math.PI) / 180, w / h, 0.02, 60)
    const view = lookAt(eye, t as number[], [0, 1, 0])
    const mvp = mul(proj, view)

    gl.useProgram(this.prog)
    gl.uniformMatrix4fv(gl.getUniformLocation(this.prog, 'uMVP'), false, mvp)
    gl.uniform3f(gl.getUniformLocation(this.prog, 'uLight'), -0.55, 0.72, -0.42)
    gl.activeTexture(gl.TEXTURE0)
    gl.uniform1i(gl.getUniformLocation(this.prog, 'uTex'), 0)

    // Coarse to fine. Each level's own texture carries its resolution, so the
    // ground near the camera is sharp without the far field being re-fetched.
    for (const lv of this.levels) {
      if (!lv?.vao || !lv.indexCount) continue
      gl.bindTexture(gl.TEXTURE_2D, lv.tex)
      gl.bindVertexArray(lv.vao)
      gl.drawElements(gl.TRIANGLES, lv.indexCount, lv.idxType, 0)
    }
    gl.bindVertexArray(null)

    this.mvp = mvp
    this.onFrame?.()
  }

  /**
   * World position -> CSS-pixel screen position, using the same matrix the
   * mesh was drawn with. Returns null when behind the camera or off-screen.
   */
  project(wx: number, wy: number, heightMetres: number): [number, number] | null {
    const s = 2 / this.spanWorld
    const x = (wx - this.centre[0]) * s
    const z = -(wy - this.centre[1]) * s
    const y = Math.max(heightMetres - WATER_LEVEL, 0) * this.exaggeration * s
    const m = this.mvp
    const cx = m[0] * x + m[4] * y + m[8] * z + m[12]
    const cy = m[1] * x + m[5] * y + m[9] * z + m[13]
    const cw = m[3] * x + m[7] * y + m[11] * z + m[15]
    if (cw <= 0.0001) return null
    const r = this.canvas.getBoundingClientRect()
    return [((cx / cw) * 0.5 + 0.5) * r.width, (1 - ((cy / cw) * 0.5 + 0.5)) * r.height]
  }

  destroy() {
    cancelAnimationFrame(this.raf)
    if (this.onKey) window.removeEventListener('keydown', this.onKey)
  }
}
