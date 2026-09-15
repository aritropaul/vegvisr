import { defineConfig } from 'vite'
import wasm from 'vite-plugin-wasm'
import topLevelAwait from 'vite-plugin-top-level-await'

export default defineConfig({
  plugins: [wasm(), topLevelAwait()],
  // portless allocates the port and proxies https://valheim.lcl to it.
  server: {
    host: '127.0.0.1',
    port: Number(process.env.PORT) || 5173,
    strictPort: true,
  },
  // Plugins do NOT propagate to production worker builds; the tile worker loads
  // the wasm module, so it needs its own plugin pipeline or `vite build` fails
  // with "ESM integration proposal for Wasm is unsupported".
  worker: {
    format: 'es',
    plugins: () => [wasm(), topLevelAwait()],
  },
  build: {
    target: 'esnext',
    // Keep .wasm a real file so it stream-compiles instead of being
    // base64-inlined into JS.
    assetsInlineLimit: 0,
  },
})
