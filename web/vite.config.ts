import { createReadStream, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import react from '@vitejs/plugin-react';
import type { Plugin } from 'vite';
import { defineConfig } from 'vitest/config';

const LOCAL_EXPORT = fileURLToPath(new URL('./local/books.json', import.meta.url));

/**
 * Dev server only: serve `local/books.json` (the git-ignored output of
 * `npm run export-store`) at /local-data/books.json, so your own wishlist
 * opens without a file picker. It is never part of a build: `local/` is
 * outside `public/`, and this plugin only hooks the dev server.
 */
function localExport(): Plugin {
  return {
    name: 'relate-books-local-export',
    apply: 'serve',
    configureServer(server) {
      // The app asks here first, so a missing export is not a 404 in the console.
      server.middlewares.use('/local-data/status', (_req, res) => {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Cache-Control', 'no-store');
        res.end(JSON.stringify({ available: existsSync(LOCAL_EXPORT) }));
      });
      server.middlewares.use('/local-data/books.json', (req, res) => {
        if (!existsSync(LOCAL_EXPORT)) {
          res.statusCode = 404;
          res.end();
          return;
        }
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Content-Length', statSync(LOCAL_EXPORT).size);
        res.setHeader('Cache-Control', 'no-store');
        if (req.method === 'HEAD') {
          res.end();
          return;
        }
        createReadStream(LOCAL_EXPORT).pipe(res);
      });
    },
  };
}

export default defineConfig({
  // Relative asset URLs, so the build can be served from any path.
  base: './',
  plugins: [react(), localExport()],
  worker: { format: 'es' },
  build: {
    target: 'es2023',
    chunkSizeWarningLimit: 8000,
  },
  optimizeDeps: {
    // The engine and the model runtimes load their own .wasm files by URL;
    // pre-bundling them breaks those URLs.
    exclude: ['@relate/relate-wasm', '@mlc-ai/web-llm', '@huggingface/transformers'],
  },
  test: {
    include: ['tests/**/*.test.ts'],
    environment: 'node',
    testTimeout: 30_000,
  },
});
