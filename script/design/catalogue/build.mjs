import { build, transformWithEsbuild } from 'vite';
import vue from '@vitejs/plugin-vue';
import tailwindcss from 'tailwindcss';
import loadConfig from 'tailwindcss/loadConfig.js';
import autoprefixer from 'autoprefixer';
import postcss from 'postcss';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../../..');
const output = path.resolve(
  process.argv[2] || path.join(os.tmpdir(), 'onelink-catalogue')
);
await fs.mkdir(output, { recursive: true });

// Collect only the gallery and its real UI dependencies. Product tokens/plugins
// are reused unchanged; no application entrypoint, store or router is loaded.
const sources = new Set();
const visit = async file => {
  if (sources.has(file)) return;
  sources.add(file);
  const text = await fs.readFile(file, 'utf8');
  const imports = [...text.matchAll(/(?:from\s*|import\s*)['"]([^'"]+)['"]/g)];
  await Promise.all(
    imports.map(async match => {
      const specifier = match[1];
      let candidate;
      if (specifier.startsWith('next/'))
        candidate = path.join(
          root,
          'app/javascript/dashboard/components-next',
          specifier.slice(5)
        );
      else if (specifier.startsWith('dashboard/'))
        candidate = path.join(root, 'app/javascript', specifier);
      else if (specifier.startsWith('shared/'))
        candidate = path.join(root, 'app/javascript', specifier);
      else if (specifier.startsWith('.'))
        candidate = path.resolve(path.dirname(file), specifier);
      if (!candidate) return;
      const candidates = await Promise.all(
        ['', '.js', '.vue', '/index.js'].map(async suffix => {
          const resolved = candidate + suffix;
          if (!/\.(?:js|vue)$/.test(resolved)) return null;
          try {
            await fs.access(resolved);
            return resolved;
          } catch (error) {
            if (error.code === 'ENOENT' || error.code === 'ENOTDIR')
              return null;
            throw error;
          }
        })
      );
      const resolved = candidates.find(Boolean);
      if (resolved) await visit(resolved);
    })
  );
};
await visit(path.join(here, 'main.js'));
const productTheme = loadConfig(path.join(root, 'tailwind.config.js'));

const result = await build({
  configFile: false,
  root,
  publicDir: false,
  plugins: [vue()],
  define: {
    'process.env.NODE_ENV': JSON.stringify('production'),
    __VUE_OPTIONS_API__: true,
    __VUE_PROD_DEVTOOLS__: false,
    __VUE_PROD_HYDRATION_MISMATCH_DETAILS__: false,
  },
  resolve: {
    alias: {
      next: path.join(root, 'app/javascript/dashboard/components-next'),
      dashboard: path.join(root, 'app/javascript/dashboard'),
      shared: path.join(root, 'app/javascript/shared'),
    },
    dedupe: ['vue'],
  },
  css: {
    postcss: {
      plugins: [
        tailwindcss({ ...productTheme, content: [...sources], safelist: [] }),
        autoprefixer(),
      ],
    },
    preprocessorOptions: {
      scss: { includePaths: [path.join(root, 'app/javascript')] },
    },
  },
  build: {
    write: false,
    minify: 'esbuild',
    cssCodeSplit: false,
    sourcemap: false,
    lib: {
      entry: path.join(here, 'main.js'),
      formats: ['iife'],
      name: 'OneLinkCatalogue',
    },
    rollupOptions: {
      output: { inlineDynamicImports: true },
    },
  },
});
const files = Array.isArray(result)
  ? result.flatMap(item => item.output)
  : result.output;
let js = files
  .filter(file => file.type === 'chunk')
  .map(file => file.code)
  .join('\n');
let css = files
  .filter(file => file.type === 'asset' && file.fileName.endsWith('.css'))
  .map(file => String(file.source))
  .join('\n');
// Vite preserves whitespace in ES library output. Compact the standalone page
// explicitly and retain UTF-8 translations rather than long unicode escapes.
js = (
  await transformWithEsbuild(js, 'catalogue.js', {
    minify: true,
    charset: 'utf8',
    legalComments: 'none',
    target: 'es2020',
  })
).code;

// All catalogue specimens use normal font style. Keep the exact product font
// faces for Geist and Geist Mono, without embedding unused italic faces.
const parsedCss = postcss.parse(css);
parsedCss.walkAtRules('font-face', rule => {
  if (
    rule.nodes.some(
      node => node.prop === 'font-style' && node.value === 'italic'
    )
  )
    rule.remove();
});
css = parsedCss.toString();
const fontUrls = [...css.matchAll(/url\(["']?(\/fonts\/[^"')]+)["']?\)/g)];
const fontReplacements = await Promise.all(
  fontUrls.map(async match => {
    const font = await fs.readFile(
      path.join(root, 'public', decodeURIComponent(match[1]))
    );
    return [match[0], `url(data:font/woff2;base64,${font.toString('base64')})`];
  })
);
css = fontReplacements.reduce(
  (text, [url, data]) => text.replaceAll(url, data),
  css
);
if (/url\(["']?\/(?!\/)/.test(css))
  throw new Error('Unresolved absolute asset URL in catalogue CSS');

js = js.replace(/<\/script/gi, '<\\/script');
css = css.replace(/<\/style/gi, '<\\/style');
const html = `<!doctype html><html lang="ru" dir="ltr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>OneLink — дизайн-система</title><style>${css}</style></head><body class="onelink-catalogue"><div id="app"></div><script>${js}</script></body></html>`;
const packed = gzipSync(Buffer.from(html), { level: 9 }).toString('base64');
// The inline visual expands the SAME offline document locally. No CDN, API,
// service or second component implementation is involved. Retain the document
// and window so Orca theme/resize bridge listeners survive expansion.
const inline = `<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OneLink — дизайн-система</title><style id="catalogue-loader-style">body{margin:24px;font:14px system-ui;color:var(--foreground);background:var(--background)}</style></head><body><p role="status">Открываю дизайн-систему OneLink…</p><script>const catalogueNonce=document.currentScript?.nonce;(async()=>{const b=Uint8Array.from(atob("${packed}"),c=>c.charCodeAt(0));const stream=new Blob([b]).stream().pipeThrough(new DecompressionStream("gzip"));const html=await new Response(stream).text();const page=new DOMParser().parseFromString(html,"text/html");document.title=page.title;document.documentElement.lang=page.documentElement.lang;document.documentElement.dir=page.documentElement.dir;page.head.querySelectorAll("style").forEach(style=>document.head.appendChild(style));document.getElementById("catalogue-loader-style").remove();document.body.className=page.body.className;const scripts=Array.from(page.body.querySelectorAll("script"));scripts.forEach(script=>script.remove());document.body.replaceChildren(...page.body.childNodes);scripts.forEach(original=>{const script=document.createElement("script");if(catalogueNonce)script.nonce=catalogueNonce;script.textContent=original.textContent;document.body.appendChild(script)})})().catch(()=>{document.body.textContent="Не удалось открыть каталог. Откройте отдельный HTML-файл из сообщения."})</script></body></html>`;
if (Buffer.byteLength(inline) >= 512 * 1024)
  throw new Error('Inline catalogue exceeds Orca 512 KiB limit');
const filename = path.join(output, 'onelink-design-system-offline.html');
const inlineFilename = path.join(output, 'onelink-design-system-inline.html');
await fs.writeFile(filename, html);
await fs.writeFile(inlineFilename, inline);
process.stdout.write(
  JSON.stringify({
    filename,
    inlineFilename,
    bytes: Buffer.byteLength(html),
    inlineBytes: Buffer.byteLength(inline),
    sourceFiles: sources.size,
  }) + '\n'
);
