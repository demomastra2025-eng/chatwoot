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

The legacy colour class check remains at
`script/design/check-unresolved-classes.js`. It scans a built Vite stylesheet;
run it after `bin/vite build` to detect unresolved classes. The production
colour baseline is checked independently with
`node script/design/check-prod-theme.js`.
