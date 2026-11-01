# OneLink design-system catalogue

Standalone visual reference for the `onelink-design-system` skill. It imports
the real dashboard Vue components and the product palette, Geist fonts, base
styles and typography. It does not load the application store, routes or APIs.
All sample data and changes are local to the page.

From the repository root, with its development dependencies installed:

```sh
/opt/node22/bin/node script/design/catalogue/build.mjs /tmp/onelink-catalogue
/opt/node22/bin/node script/design/catalogue/build.mjs /tmp/onelink-catalogue --cdn
```

- `onelink-design-system-offline.html`: one self-contained file, including
  JavaScript, styles, normal-style Geist/Geist Mono fonts and icons. Open it in
  a browser or download it; it does not require the application or a server.
- `onelink-design-system-cdn.html`: smaller than 512 KiB for Orca inline visuals.
  Component code, styles, translations and fonts remain inline. Pinned public
  library modules load from `esm.sh`, so this variant needs a network connection.

The five groups cover foundations, actions, fields, layouts and data. Light and
dark themes and ru/kk/en are available. Controls retain state between groups;
refresh resets the demonstration. Supported component variants follow the skill.

The plain page heading belongs to this isolated catalogue host. The product's
`BaseSettingsHeader` is not imported because its `BackButton` imports the full
application router. This does not change the header rule for product pages.
The host supplies only the `accounts/isRTL` getter required by Teleport.

Existing component limits remain visible: `PaginationFooter` has icon controls
without individual accessible names, and `RadioCard` uses per-item radio names.
This gallery does not silently fork or restyle those components. Browser checks
must cover desktop/mobile, both themes, controls, error/loading/empty states and
the actual generated files. A catalogue is a reference for owner review, not
automatic approval of every existing component or production screen.
