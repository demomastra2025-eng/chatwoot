/// <reference types="vitest" />

/**
What's going on with library mode?

Glad you asked, here's a quick rundown:

1. vite-plugin-ruby will automatically bring all the entrypoints like dashbord and widget as input to vite.
2. vite needs to be in library mode to build the SDK as a single file. (UMD) format and set `inlineDynamicImports` to true.
3. But when setting `inlineDynamicImports` to true, vite will not be able to handle mutliple entrypoints.

This puts us in a deadlock, now there are two ways around this, either add another separate build pipeline to
the app using vanilla rollup or rspack or something. The second option is to remove sdk building from the main pipeline
and build it separately using Vite itself, toggled by an ENV variable.

`BUILD_MODE=library bin/vite build` should build only the SDK and save it to `public/packs/js/sdk.js`
`bin/vite build` will build the rest of the app as usual. But exclude the SDK.

We need to edit the `asset:precompile` rake task to include the SDK in the precompile list.
*/
import { defineConfig } from 'vite';
import ruby from 'vite-plugin-ruby';
import path from 'path';
import vue from '@vitejs/plugin-vue';

const isLibraryMode = process.env.BUILD_MODE === 'library';
const isTestMode = process.env.TEST === 'true';
const devServerBindHost = process.env.VITE_DEV_SERVER_BIND_HOST || '0.0.0.0';
const devServerHost = process.env.VITE_DEV_SERVER_HOST || '127.0.0.1';
const devServerPort = Number(process.env.VITE_DEV_SERVER_PORT || 3036);
const devServerProtocol = process.env.VITE_DEV_SERVER_PROTOCOL;
const devServerClientPort = process.env.VITE_DEV_SERVER_CLIENT_PORT
  ? Number(process.env.VITE_DEV_SERVER_CLIENT_PORT)
  : undefined;
const devServerHmrPath = process.env.VITE_DEV_SERVER_HMR_PATH || undefined;

const vueOptions = {
  template: {
    compilerOptions: {
      isCustomElement: tag => ['ninja-keys'].includes(tag),
    },
  },
};

let plugins = [ruby(), vue(vueOptions)];

if (isLibraryMode) {
  plugins = [];
} else if (isTestMode) {
  plugins = [vue(vueOptions)];
}

export default defineConfig({
  plugins: plugins,
  server: {
    host: devServerBindHost,
    port: devServerPort,
    strictPort: true,
    hmr: {
      host: devServerHost,
      port: devServerPort,
      ...(devServerProtocol ? { protocol: devServerProtocol } : {}),
      ...(devServerClientPort ? { clientPort: devServerClientPort } : {}),
      ...(devServerHmrPath ? { path: devServerHmrPath } : {}),
    },
  },
  build: {
    rollupOptions: {
      output: {
        // [NOTE] when not in library mode, no new keys will be addedd or overwritten
        // setting dir: isLibraryMode ? 'public/packs' : undefined will not work
        ...(isLibraryMode
          ? {
              dir: 'public/packs',
              entryFileNames: chunkInfo => {
                if (chunkInfo.name === 'sdk') {
                  return 'js/sdk.js';
                }
                return '[name].js';
              },
            }
          : {}),
        inlineDynamicImports: isLibraryMode, // Disable code-splitting for SDK
      },
    },
    lib: isLibraryMode
      ? {
          entry: path.resolve(__dirname, './app/javascript/entrypoints/sdk.js'),
          formats: ['iife'], // IIFE format for single file
          name: 'sdk',
        }
      : undefined,
  },
  resolve: {
    alias: [
      {
        find: /^vue$/,
        replacement: 'vue/dist/vue.esm-bundler.js',
      },
      {
        find: 'components',
        replacement: path.resolve('./app/javascript/dashboard/components'),
      },
      {
        find: 'next',
        replacement: path.resolve('./app/javascript/dashboard/components-next'),
      },
      {
        find: 'v3',
        replacement: path.resolve('./app/javascript/v3'),
      },
      {
        find: 'dashboard',
        replacement: path.resolve('./app/javascript/dashboard'),
      },
      {
        find: 'helpers',
        replacement: path.resolve('./app/javascript/shared/helpers'),
      },
      {
        find: 'shared',
        replacement: path.resolve('./app/javascript/shared'),
      },
      {
        find: 'survey',
        replacement: path.resolve('./app/javascript/survey'),
      },
      {
        find: 'widget',
        replacement: path.resolve('./app/javascript/widget'),
      },
      {
        find: 'assets',
        replacement: path.resolve('./app/javascript/dashboard/assets'),
      },
      {
        find: /^vue-cal$/,
        replacement: path.resolve(
          __dirname,
          './app/javascript/vendor/vue-cal/index.js'
        ),
      },
    ],
  },
  test: {
    environment: 'jsdom',
    include: ['app/**/*.{test,spec}.?(c|m)[jt]s?(x)'],
    coverage: {
      reporter: ['lcov', 'text'],
      include: ['app/**/*.js', 'app/**/*.vue'],
      exclude: [
        'app/**/*.@(spec|stories|routes).js',
        '**/specs/**/*',
        '**/i18n/**/*',
      ],
    },
    globals: true,
    outputFile: 'coverage/sonar-report.xml',
    pool: 'threads',
    poolOptions: {
      threads: {
        singleThread: false,
      },
    },
    server: {
      deps: {
        inline: ['tinykeys', '@material/mwc-icon'],
      },
    },
    setupFiles: ['fake-indexeddb/auto', 'vitest.setup.js'],
    mockReset: true,
    clearMocks: true,
  },
});
