## Onelink Documentation

This is the documentation workspace for the Onelink product fork. It contains:

- Onelink-specific platform and architecture documentation
- inherited operational and deployment documentation from Chatwoot where still applicable
- API and development documentation for working inside the fork

### 👩‍💻 Development

Install the [Mintlify CLI](https://www.npmjs.com/package/mint) to preview the documentation changes locally. To install, use the following command

```
npm i -g mint
```

Run the following command at the root of the docs folder (where `docs.json` is)

```
mint dev
```

### 😎 Publishing Changes

Changes should reflect Onelink terminology, architecture direction, and product goals when editing the active docs surface.

Use PR previews or local `mint dev` before changing top-level navigation or landing pages.
