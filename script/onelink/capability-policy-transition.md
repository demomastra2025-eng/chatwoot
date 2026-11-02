# Capability policy transition, 02.11.2026

This operator-only mode implements owner decision 17: retain each profile's
current effective Agent/Assistant grants, prompt and voice behavior; give MCP the
same two canonical scopes, including existing `resolve_conversation`, and remove
old broader MCP default-all grants. It never grants all tools globally. There is
one runtime reader, `capabilities` v1. Ordinary migration remains strict.

Source preparation does not authorize deployment, changing live profiles,
auto-replies, sends, calls or tool execution. No schema change is required.

## Prepare and inspect one profile

Run only in an environment specifically authorized for this operation. The
following are command templates, not permission to run against live data:

```sh
RAILS_ENV=production TRANSITION_POLICY=preserve_ai_expand_mcp_20261102 \
  ASSISTANT_ID=<profile-id> ACCOUNT_ID=<account-id> ACTOR_ID=<platform-actor-id> \
  bundle exec rake captain:capabilities:plan
```

This locks the current actor first, then Account and Assistant, consistent with
staff reactivation. It reads and returns a manifest with IDs,
canonical scope selections, dormant selections, quarantined IDs, complete before
and after tool-ID sets, exact per-surface MCP additions/removals and source digest.
It contains no prompts, raw config, names or secrets. Keep private source/audit
storage out of public exports. The digest binds actor, profile, account, source,
workspace policy, registry/custom-tool/integration metadata and actual simulation.

Read `blockers`, both scopes and every difference. A ready policy plan must have
zero additions/removals on Agent, Assistant, prompt and voice. A stored FAQ that
is available but withheld is excluded, not converted into an active grant. Valid
unavailable selections stay in their original scope; disabled scopes stay off.
Unknown nonbinding identifiers are excluded from canonical config and listed for
explicit quarantine approval in this manifest; original legacy config and prompt
stay untouched in private storage. No aliases are inferred or tools restored.

Malformed config/IDs, unknown scopes, wrong-scope selections, legacy prompt/scenario
conversion requirements and unrepresentable behavior remain blocked. Preparation
never performs external MCP discovery. Enabled external MCP servers or unresolved
`mcp__` IDs stay blocked until their source catalog can be proven separately; this
mode does not infer their dormant permissions from a missing discovery result.

## Apply only an explicitly approved ready manifest

After reviewing the manifest and obtaining environment-specific approval:

```sh
RAILS_ENV=production TRANSITION_POLICY=preserve_ai_expand_mcp_20261102 \
  ASSISTANT_ID=<same-profile-id> ACCOUNT_ID=<same-account-id> ACTOR_ID=<same-actor-id> \
  SOURCE_DIGEST=<reviewed-source-digest> CONFIRM=yes \
  bundle exec rake captain:capabilities:activate
```

Without `CONFIRM=yes` activation is a read-only preparation. Apply reloads the
actor, locks User then Account then Assistant, reloads policy/context and replans. A stale
digest, wrong actor/account or blocker causes no write. It uses the existing
activation service and private migration snapshot, adding decision provenance,
manifest digest and quarantine/difference audit. All existing model validators run
on an isolated persisted copy of the canonical candidate. Only legacy source
rewriting and the redundant voice account lock are suppressed for that internal
copy; exact proven nonbinding prompt refs retain their old ignored status. Any
other validator error or callback attribute mutation blocks activation. The
original instance never receives this validation context. Public serializers exclude that
snapshot. Exact repeat is a no-op only while the original transition and current
canonical state still agree; later edits invalidate it.

Run ordinary `captain:capabilities:preflight` afterward. This global gate remains
strict and requires every persisted profile to have a valid canonical contract;
a ready legacy policy plan alone does not pass. Strict migrations retain their existing guarded rollback. Policy migrations
refuse generic rollback: removing canonical config could restore the broader MCP
default-all rights that this decision removed. A reverse transition needs separate
review; refusal preserves canonical state and private audit.
Other release, billing, workspace, voice and quality gates remain separate.
