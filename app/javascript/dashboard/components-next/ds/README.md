# Design system A "Graphite"

Light paper, thin lines, calm big numbers, one accent. Colour only on charts
and statuses; a status is always a dot plus a word.

## Token map

Token names did not change; their values now follow variant A. Values are
`R G B` channels in `app/javascript/dashboard/assets/scss/_next-colors.scss`
(`:root` = light, `.dark` = dark). Super admin imports the same file.

| Variant A role | CSS variable | Tailwind class | Light | Dark |
|---|---|---|---|---|
| Page background | `--background-color`, `--surface-1`, `--slate-1` | `bg-n-background`, `bg-n-surface-1` | `#fafafa` | `#0e0e10` |
| Surface (cards, popovers) | `--solid-1`, `--solid-2`, `--card-color`, `--surface-2` | `bg-n-solid-2`, `bg-n-card` | `#ffffff` | `#141417` |
| Raised surface | `--solid-3`, `--solid-active`, `--surface-active` | `bg-n-solid-3` | `#ffffff` | `#1d1d22` |
| Line | `--border-weak`, `--border-container` | `border-n-weak`, `outline-n-container` | `#e6e6e8` | `#26262b` |
| Strong line (derived) | `--border-strong` | `border-n-strong` | `#dcdce0` | `#323238` |
| Text | `--slate-12` | `text-n-slate-12` | `#111113` | `#ededf0` |
| Muted text | `--slate-11` | `text-n-slate-11` | `#6b6f76` | `#8d9098` |
| Hover / selected | `--slate-3` | `bg-n-slate-3` | `#f0f0f2` | `#1d1d22` |
| Accent | `--brand-color`, `--brand-solid`, `--blue-11` | `text-n-brand`, `bg-n-brand`, `bg-n-brand-solid`, `text-n-blue-11` | `#3a5bd9` | `#7b93f5` |
| Text on accent fill | `--brand-contrast` | `text-n-brand-contrast` | `#ffffff` | `#0e0e10` |
| Accent solid / hover (derived) | `--blue-9`, `--blue-10` | `bg-n-blue-9`, `bg-n-blue-10` | `#3a5bd9` / `#314cb4` | `#3a5bd9` / `#5a75df` |
| Accent focus ring | `--border-blue` | `outline-n-blue-border` | accent at 50% | accent at 50% |
| Status good (new) | `--status-good` | `bg-n-status-good` | `#2f8f5b` | `#4fb883` |
| Status warn (new) | `--status-warn` | `bg-n-status-warn` | `#b7791f` | `#d6a24a` |
| Status bad (new) | `--status-bad` | `bg-n-status-bad` | `#c53b3b` | `#e06b6b` |
| Ordinal chart ramp (new) | `--chart-1` ... `--chart-5` | `bg-n-chart-1` ... | `#2a3d8a` `#324cb1` `#3a5bd9` `#657fe1` `#899de8` | `#7b93f5` `#6b7fd1` `#5a6aae` `#4c598f` `#3f4974` |
| Comparison series | `--slate-9` (unchanged) | `stroke-n-slate-9` | `#8b8d98` | `#696e77` |

Radius and type tokens live in `tailwind.config.js`: `rounded-ds-card` (10px),
`rounded-ds-control` (7px), `text-ds-caption` (12.5px), `text-ds-figure`
(30px / 600 / -0.03em). No shadows anywhere.

"Derived" rows are not in the variant A brief; they are the nearest values that
keep the existing scale monotonic. The ordinal ramp was checked with the dataviz
palette validator (`--ordinal`, light on `#ffffff`, dark on `#141417`): one hue,
monotone lightness, visible steps, light end at 2.6:1 / 2.1:1 against the
surface. The comparison grey passes CVD and normal-vision separation against
the accent in both themes.

Unchanged on purpose: the other Radix scales (`n-iris`, `n-ruby`, `n-amber`,
`n-teal`, ...), translucent overlays (`n-alpha-*`), label and button tokens.

### Legacy palette names

`tailwind.config.js` used to *replace* the colour palette, so `bg-amber-50`,
`text-emerald-800`, `border-rose-200`, `bg-blue-100`, `text-gray-500`,
`bg-black/40`, `dark:bg-red-950/40` and similar produced no CSS at all. They now
resolve through `theme.extend.colors` to five token-backed ramps
(`--compat-<hue>-50 ... 950` in `_next-colors.scss`):

| Legacy names | Ramp | 600 shade |
|---|---|---|
| `blue`, `indigo`, `cyan` | accent | `#3a5bd9` |
| `emerald` | good | `#2f8f5b` |
| `amber` | warn | `#b7791f` |
| `rose`, `red-950` | bad | `#c53b3b` |
| `gray` | neutral (variant A greys) | `#6b6f76` |

These ramps do not switch with the theme, exactly like stock Tailwind shades:
older screens pair them with explicit `dark:` classes and flipping them would
break those pairs. They exist so old screens render as written; new code must
use the n-* tokens and the components below.

### Unresolved class check

```
bin/vite build   # writes public/vite/assets/*.css
node script/design/check-unresolved-classes.js            # fails on regressions
node script/design/check-unresolved-classes.js --list     # every class per file
node script/design/check-unresolved-classes.js --update-baseline
```

The script reads every class selector from the built CSS and scans
`app/javascript/**/*.{vue,js,ts}` and `app/views/**/*.erb` for colour utilities
(`bg-`, `text-`, `border-`, `ring-`, `outline-`, `divide-`, `fill-`, `stroke-`,
gradients, ... with a palette or `n-*` colour) that have no rule. Specs and
`@apply` lines are skipped (the build itself fails on a bad `@apply`). The
committed `script/design/unresolved-classes.baseline.json` holds the allowed
number of distinct unresolved classes per file; the check fails when a file goes
above it. When a screen is fixed, rerun with `--update-baseline` so the number
can only go down.

## Components (`components-next/ds`)

All strings come from `DESIGN_SYSTEM.*` in `i18n/locale/{en,ru,kk}/designSystem.json`.

| Component | Use |
|---|---|
| `DsCard` | Card: 10px radius, hairline border, 18x20 padding. Props `title`, `subtitle`, `padded`, `as`; slots `default`, `header`, `actions`. |
| `DsStatGroup` | Key indicators in ONE card with thin vertical dividers. `items: [{ key, label, value, note }]`; slots `value`, `note`. Caption above, 30px figure. |
| `DsTable` | Thin row lines, muted header, numeric columns end-aligned with tabular figures. `columns: [{ key, label, numeric }]`, `rows`, `caption`; slots `cell-<key>`. Empty state built in. |
| `DsMeter` | 4px meter, `value`/`max`, `tone` = accent, warn, bad or auto (warn at 80%, bad at 95%). Track is the same hue at 15%. |
| `DsStatusDot` | Dot + word. `status` = good, warn, bad, neutral; `label` overrides the default word. |
| `DsSegmented` | Period switch. `options: [{ value, label }]`, `v-model`, arrow keys. |
| `DsChartFrame` | Chart card. `kind="line"`: `labels`, up to two `series` on one axis (accent, then grey), `secondary` = separate small column panel under the plot, never a second axis. `kind="bars"`: funnel / stages in one hue, earlier stage = stronger step, value and share at the bar end. Legend from two series, three hairline gridlines, crosshair tooltip (pointer and arrow keys; `tooltip` slot gets `{ index, label, rows }`, `hover` event), "Show as table" toggle, `loading` keeps the last render dimmed, `error` emits `retry`. |
| `DsState` | `state` = empty, loading or error with default texts; error offers retry. |

Rules for screens built with them:

- No icons in coloured tiles, no emoji, no gradients, no coloured cards, no
  shadows, no hex or inline colours in components: n-* tokens only.
- One accent. Status colours only mean status and always come with a word.
- Big numbers: proportional figures; tables and axes: `tabular-nums`.
- Charts: one axis; a second measure goes to `secondary` or its own chart;
  every chart keeps its table view.
- Sidebar navigation is plain text links (`bg-n-slate-3` marks the current one).

## Super admin (ERB)

`app/javascript/dashboard/assets/scss/super_admin/_ds.scss` is part of the
super admin pack (`super_admin/index.scss`, which now imports the shared
tokens instead of its own stale copy). Rules for ERB views:

1. Build new or restyled pages only from these classes plus layout utilities
   (`flex`, `grid`, `gap-*`, `p-*`). Colours come from the classes or n-*
   utilities (`text-n-slate-11`), never from palette names or hex.
2. Card: `<section class="ds-card">` with optional
   `<header class="ds-card__header"><h2 class="ds-card__title">…</h2><span class="ds-card__subtitle">…</span></header>`
   and `<div class="ds-card__body">`. A table inside a card goes directly
   under the header without `ds-card__body` so its rows run edge to edge.
3. Key indicators: `<dl class="ds-stat-group">` with
   `<div class="ds-stat"><dt class="ds-stat__label">…</dt><dd class="ds-stat__value">…</dd><dd class="ds-stat__note">…</dd></div>`.
4. Tables: `<table class="ds-table">`; numeric cells and their header get `ds-num`.
5. Meter: `<span class="ds-meter ds-meter--warn"><span class="ds-meter__fill" style="width: 88%"></span></span>`
   (width is the only inline style allowed). Modifiers: none (accent), `--warn`, `--bad`.
6. Status: `<span class="ds-status ds-status--good">В норме</span>`; the word is
   mandatory and comes from `I18n.t`, in ru, en and kk.
7. Period switch: `<nav class="ds-segmented">` with links; the current one has
   `aria-current="page"` (buttons: `aria-pressed="true"`).
8. Dark mode follows the `.dark` class on `<html>` or `<body>`, the same switch
   as the dashboard. Super admin has no theme switch of its own yet, so ERB
   pages render light until one is added.

## Sample page

`script/design/sample/` renders every component and the `.ds-*` classes
with demo data, outside the app bundle:

```
node_modules/.bin/vite build --config script/design/sample/vite.config.mjs
# serve tmp/ds-sample and open index.html?theme=light or ?theme=dark
# (&locale=en|kk, &tooltip=1 opens the chart tooltip for screenshots)
```
