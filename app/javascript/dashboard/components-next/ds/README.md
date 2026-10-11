# Dashboard components

These components remain available to dashboard screens. Their `n-*` colour
classes use the production values in `_next-colors.scss`. The added status and
chart tokens alias the existing production palette. Radius and type utilities
(`rounded-ds-card`, `rounded-ds-control`, `text-ds-caption`,
`text-ds-figure`) remain defined in `tailwind.config.js`.

| Component | Use |
|---|---|
| `DsCard` | Card with title, subtitle, padding and header/action slots. |
| `DsStatGroup` | Grouped indicators with labels, values and notes. |
| `DsTable` | Table with numeric columns and an empty state. |
| `DsMeter` | Value/max meter with accent, warning and bad tones. |
| `DsStatusDot` | Status dot with a word label. |
| `DsSegmented` | Keyboard accessible option switch. |
| `DsChartFrame` | Line or bar chart with tooltip, legend and table view. |
| `DsState` | Empty, loading and error states. |

Chart axis headroom and pointer-to-plot coordinate mapping are covered by the
component specs. Component strings come from `DESIGN_SYSTEM.*` in the locale
files.

## Page templates

Use `BaseSettingsHeader` for page titles and the existing outer page padding
(`px-6 pt-4 pb-8` in `SettingsWrapper`).

| Template | Layout |
|---|---|
| Form | Center a `w-full max-w-3xl` column. Stack `SectionLayout` sections with `with-border` dividers; put actions directly below their form. |
| List or table | Use the full content width with the shared title and outer padding. |
| Board | Use the full content width; keep the title in place while columns scroll inside the board. |

For routes rendered through `SettingsWrapper`, set `route.meta.pageWidth` to
`'form'` (`max-w-3xl`) or `'full'` (`max-w-none`). Omit it or use `'default'`
for the existing `max-w-5xl` width. Keep `max-w-*` off the outer list, table,
and board containers; use it only for a form column or content that needs a
local limit. Table-cell `max-w-0` for truncation is fine.

## Blocks (owner rule, Chatwoot conventions)

A **block** is a rounded frame with inner padding that groups related settings
or content. Blocks are required: in the light theme a block is visible only
through its outline (`solid-*` and `surface-*` are almost the same white), so
removing a block removes the grouping. The owner's rule is **no block inside a
block**. It does **not** mean "no blocks".

Allowed recipes (all `rounded-xl`; draw frames with
`outline outline-1 -outline-offset-1`, never with `border` on the same element):

| Recipe | Classes | Use |
|---|---|---|
| Toggle block | `SettingsToggleSection` (`outline-n-weak`, no background, header `px-4 py-3`, dependent fields in `#editor`) | A setting with a switch and optional dependent fields. |
| Toggle list | toggle-block frame + `divide-y divide-n-weak`, rows `flex items-start justify-between gap-3 px-4 py-3` | A group of switches: one block for the whole group, never one block per switch and never bare switches. |
| Feature card | `flex flex-col outline outline-1 outline-n-container rounded-xl bg-n-solid-2 divide-y divide-n-weak`, header `px-5 py-4`, body `px-5 py-4 grid gap-5` (see `AutoResolve.vue`) | A feature with a title, a description and several controls. |
| Inline control block | `bg-n-solid-1 p-4 outline outline-1 outline-n-weak rounded-xl`, heading outside above it | A compact group of fields inside a form. |
| Repeated item | `CardLayout` (`px-6 py-5`, compact `px-4 py-3`), stacked with `gap-4` | Rules, steps, tools, agents, channels. |
| Report block | `rounded-xl outline outline-1 outline-n-container bg-n-solid-2 shadow px-6 py-5` | Report totals, charts, tables. |

Rules:

- **No nesting.** Inside a block nothing else may be rounded and framed
  (outline, border or filled background), except real form controls
  (`Input`, `Select`, `TextArea`, `rounded-lg`), buttons, and the Chatwoot
  patterns that live inside a toggle block: `RadioCard` tiles and `Banner`s.
  Instead of an inner block use rows divided by `divide-y divide-n-weak`, a
  sub-area `border-t border-n-weak pt-4`, a plain sub-heading
  (`text-heading-3 text-n-slate-12` + `text-body-main text-n-slate-11`), or a
  tinted full-bleed area `-mx-4 border-t border-n-weak bg-n-alpha-1 px-4 py-2`
  (no radius, no border). A drawer or dialog is already a frame: inside it use
  unframed groups separated by `border-t border-n-weak pt-6`.
- **Never strip a single block.** A block that is not inside another block
  stays. A flat `SectionLayout` (divider + heading) is for plain form pages
  (account, profile); a block may sit inside a flat section.
- **Spacing.** Page gutter `px-6` everywhere. Inside toggle blocks, lists,
  side panels and drawers `px-4`; inside feature cards `px-5` for the header
  and the rows. Page header to body `gap-4`; stacked blocks `gap-6` (`gap-4`
  for a stack of toggle blocks); block body `gap-5`; rows `py-3`. A control and
  its help text are one group (`flex flex-col gap-1`); separate groups with
  `gap-4`. Never draw a divider right under another divider.
- **Toggle rows.** Title on the left, switch last on the title line
  (`flex items-center justify-between gap-3`), description on its own line
  below. If the switch must sit beside a multi-line text column use
  `items-start` and `<Switch class="mt-0.5" />`; never `items-center` against
  a title + description column. No On/Off text next to a switch. Inline options
  in dialogs: switch first, label after, `gap-2`.
- **Switch.** Only `components-next/switch/Switch.vue` (36x20). Never pass
  size, translate or padding classes from a page.
- **Typography.** Page title `text-heading-1`; section or card title
  `text-heading-2`; toggle, field and tile title `text-heading-3`; description
  `text-body-main` (`text-body-para` in cards) `text-n-slate-11`; titles
  `text-n-slate-12`. Every item in one list either has a description or none.
- **Global CSS traps** (`assets/scss/_base.scss`): `<p>` has `mb-2` (add
  `mb-0`), raw `<button>` gets `px-2.5 py-1 rounded-lg align-middle` (add
  `p-0` or use `Button`), `<label>` is `font-medium leading-7` (descriptions
  inside labels need `font-normal`).
- **Colours.** `n-*` tokens only: no `bg-white`, no hex in templates or scoped
  CSS (image/QR backgrounds excepted). Transparent blocks use
  `outline-n-weak`; `outline-n-container` only together with `bg-n-solid-2`
  (it is transparent in dark mode).
- **Radius and shadow.** `rounded-xl` for blocks, cards, tiles and banners;
  `rounded-lg` for inputs and buttons. No `rounded-2xl`/`rounded-3xl` on
  settings or content blocks. No shadow on cards except report blocks and
  floating elements.
- **Specs** assert "no framed element nested inside a block", never "no frame
  on the block itself".

The legacy colour class check remains at
`script/design/check-unresolved-classes.js`. It scans a built Vite stylesheet;
run it after `bin/vite build` to detect unresolved classes. The production
colour baseline is checked independently with
`node script/design/check-prod-theme.js`.
