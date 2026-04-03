# One Link OpenAPI Discovery

Use this reference when the task needs exact current path names or operation summaries.

## Current OpenAPI File Names

The current docs bundle uses these files:

- `application_swagger.json`
- `client_swagger.json`
- `platform_swagger.json`
- `other_swagger.json`

## Preferred Lookup Order

1. Search the local OpenAPI files if they are available.
2. Use the published API reference if the relevant family is documented there.
3. If a business module is not fully represented in the public reference, compare with the current UI network flow.

## Local Search Script

This skill includes:

- `scripts/search_openapi.py`

It searches path names, operation summaries, and tags inside local OpenAPI files.

## Supported Local OpenAPI Locations

The script checks these locations in order:

1. `ONE_LINK_OPENAPI_DIR` environment variable
2. `./docs/openapi`
3. `../docs/openapi`
4. `~/onelink/docs/openapi`
5. `~/.claude/skills/onelink-integrator/references/openapi`

## Example Commands

Search all surfaces:

```bash
python ~/.claude/skills/onelink-integrator/scripts/search_openapi.py conversation
```

Search only the client surface:

```bash
python ~/.claude/skills/onelink-integrator/scripts/search_openapi.py message --surface client
```

Search only the platform surface:

```bash
python ~/.claude/skills/onelink-integrator/scripts/search_openapi.py account_users --surface platform
```

## Important Caveat

If the docs and the current OpenAPI files disagree, prefer the OpenAPI files for path and contract details.
