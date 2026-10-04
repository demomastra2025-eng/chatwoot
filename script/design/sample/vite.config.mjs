// Design system sample page, outside the app bundle. From the repository root:
//   node_modules/.bin/vite --config script/design/sample/vite.config.mjs --port 5199
// and open http://127.0.0.1:5199/?theme=light (or dark), or
//   node_modules/.bin/vite build --config script/design/sample/vite.config.mjs
// and serve tmp/ds-sample.
import path from 'path';
import { fileURLToPath } from 'url';
import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import autoprefixer from 'autoprefixer';
import postcssImport from 'postcss-import';
import tailwindcss from 'tailwindcss';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');
const source = dir => path.resolve(repo, 'app/javascript', dir);

export default defineConfig({
  root: here,
  base: './',
  // keep Vite's dependency cache out of node_modules
  cacheDir: path.join(repo, 'tmp/ds-sample-cache'),
  server: { host: '127.0.0.1', fs: { strict: false } },
  plugins: [vue()],
  css: {
    postcss: {
      plugins: [
        postcssImport(),
        tailwindcss({ config: path.join(here, 'tailwind.config.js') }),
        autoprefixer(),
      ],
    },
  },
  resolve: {
    alias: [
      { find: 'next', replacement: source('dashboard/components-next') },
      { find: 'dashboard', replacement: source('dashboard') },
      { find: 'helpers', replacement: source('shared/helpers') },
      { find: 'shared', replacement: source('shared') },
      { find: 'assets', replacement: source('dashboard/assets') },
    ],
  },
  build: {
    outDir: process.env.DS_SAMPLE_OUT_DIR || path.join(repo, 'tmp/ds-sample'),
    emptyOutDir: true,
  },
});
