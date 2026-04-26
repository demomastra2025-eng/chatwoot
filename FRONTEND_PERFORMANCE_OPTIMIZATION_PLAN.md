# Frontend performance optimization backlog

Date: 2026-04-26
Project: OneLink Chatwoot (`app.one-link.kz`, `widget.one-link.kz`)

## Completed in the current stage

Goal: reduce initial load without removing features or changing UX.

Completed:

1. Route/page-level lazy loading for core dashboard areas:
   - Inbox / Conversations
   - Captain
   - Campaigns
   - Contacts / Companies / CRM
   - Settings and nested settings screens
   - Reports
   - Scheduling
   - Helpcenter
   - Notifications
2. Lazy i18n:
   - startup messages only for `ru`/`en`;
   - other locales load on demand.
3. Lazy voice/webphone:
   - `@twilio/voice-sdk` and `sip.js` no longer load in the initial bundle before a real call flow.
4. Lazy audio notification helper:
   - audio notification helper is no longer statically bundled on app boot; it loads through event/initialization paths when needed.
5. Lazy analytics/audio script helpers:
   - analytics/audio helpers are not pulled into the initial bundle and are imported dynamically at actual initialization/event time.
6. Lighter v3/login path:
   - login uses lightweight `useAlert` instead of importing the whole dashboard composables barrel.
7. Gateway gzip config prepared for JS/CSS/JSON/fonts/SVG/text assets.

Current-stage verification:

- focused frontend specs passed;
- ESLint over changed frontend files passed;
- `git diff --check` passed;
- production Vite build passed;
- independent review blockers: none;
- gateway nginx config syntax: OK.

Saved build metrics after this stage:

- login/v3 initial assets: about `2633.4 KiB raw / 606.0 KiB gzip`;
- dashboard initial assets: about `4578.7 KiB raw / 1134.6 KiB gzip`;
- main dashboard JS: about `690.4 KiB raw`;
- login raw reduction vs old production assets: about `5.2x / 80.6%`;
- dashboard raw reduction vs previous local i18n/voice-only build: about `2.3x / 56.0%`;
- main dashboard JS raw reduction: about `7.3x / 86.3%`.

## Important caveat

This is not the absolute maximum possible frontend optimization. The current stage covers the largest safe layer: initial load and route/screen-level splitting.

The next stages should be page-by-page and based on real browser waterfall/timing measurements after this stage is deployed to production.

## Next optimization stage plan

### 1. Post-deploy baseline for core pages

After deploying the current stage, measure real browser/network timings for:

1. `/app/login`
2. Dashboard shell after login
3. Inbox / Conversations
4. Captain
5. Campaigns
6. Settings overview + Inbox settings
7. Reports
8. Contacts / Companies / CRM
9. Scheduling
10. Helpcenter

For each page capture:

- HTML/API TTFB;
- JS/CSS resource waterfall;
- largest chunks;
- `Content-Encoding`;
- FCP/LCP/load;
- main-thread/parse pressure if available;
- console errors;
- fresh Rails/gateway logs excluding `/cable` noise.

### 2. CSS reduction

Problem: CSS remains relatively large even after JS route splitting.

Check:

- which CSS files are included in login/dashboard initial load;
- which styles come from global imports;
- whether CSS can be split by route/screen;
- unused legacy styles;
- Tailwind/utility/style imports that are global without needing to be.

Goal:

- reduce initial CSS for login/dashboard;
- preserve theme and visual behavior.

### 3. Shared UI chunks

Problem: large shared chunks remain, especially form/UI chunks like `Radio-*`.

Check:

- source-map contributors inside shared UI chunks;
- barrel imports from component libraries;
- all-components/all-icons imports;
- duplicated dependencies between route chunks.

Possible actions:

- split heavy UI widgets with dynamic imports;
- replace broad barrel imports with direct imports;
- isolate lightweight shared primitives;
- lazy-load heavy form widgets only on settings/reports pages where needed.

### 4. Page-internal lazy loading

Route-level lazy loading is done. The next layer is inside specific pages.

Candidates:

- Reports charts/widgets;
- rich text / markdown / emoji / attachment previews;
- Inbox settings provider forms;
- Captain tools/rules/editor components;
- Campaign builder substeps;
- CRM/contact heavy side panels;
- Helpcenter editor/import flows.

Approach:

- no blind splitting;
- measure waterfall/source-map first;
- lazy-load components below the fold, modals, tabs, and rarely-used forms.

### 5. Icon strategy

Check:

- all-icons imports;
- icon sets in initial chunks;
- lazy-loading for rare icons;
- `DashboardIcon`/FluentIcon wrapper impact on shared chunks.

### 6. Prefetch/preload UX strategy

After splitting, avoid adding visible delays during navigation.

Possible improvements:

- idle prefetch likely next route chunks after login/dashboard boot;
- prefetch on hover/focus for sidebar items;
- skeleton loaders for heavy route chunks;
- avoid prefetching everything and recreating the old huge initial load.

### 7. Bundle budget / regression guard

Add automated protection so the initial bundle does not silently grow again.

Idea:

- script reads `public/vite/.vite/manifest.json` after build;
- budget for login/dashboard initial raw/gzip sizes;
- CI/predeploy warning or failure on budget breach;
- top-chunks report.

### 8. Locale loader hardening

Not a blocker for the current stage, but useful:

- handle failed dynamic locale imports;
- protect against rapid concurrent locale switching;
- fallback to startup locale without breaking UI.

### 9. Compression improvements

After enabling gzip, verify:

- JS/CSS/JSON assets return `Content-Encoding: gzip`;
- fingerprint cache headers remain correct;
- evaluate Brotli/precompressed assets or Caddy `encode zstd gzip` if compatible with gateway architecture.

### 10. Definition of done for future optimizations

Each optimization must have:

1. before/after browser/network measurement;
2. source-map or code-path RCA;
3. tests/guard specs where eager-import regression risk exists;
4. ESLint/build green;
5. no functionality removal;
6. post-deploy smoke checks and clean logs.
