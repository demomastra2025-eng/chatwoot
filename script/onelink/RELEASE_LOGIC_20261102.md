# Logic source candidate: release gates

This branch starts at the verified DEV candidate
`abadea93f8a8e183cadd33bc04c5dffe69623de2`. It is a separate source integration.
The public DEV stays on that earlier candidate for the owner's review. A source
merge or feature-branch push does not authorize deployment or data activation.

## Frozen source packages

- Company backend: `f2cfa26e0db7f58b541dcdec64eb5caa88511c58`;
  UI: `1eb949c1292d5d9df10f9b9ce4d887fa9bc202c7`.
- AI text/config backend: `fe3a2cf354ded14c7752488bbe1d280f47e6bd95`;
  UI: `a6029c22fc38459413e4d0b5546d194ada127eaa`.
- AI usage backend: `455b3d031c43c69f0728b50a12f9766f0a8a2192`;
  required transport companion: `a3c52661a9e32f58171acb18ea25bdd0fd675688`.
- Calendar notifications: `f466ffa65a78e0b6a8bf8df71cd8a40e44c4da0f`.

These are 21 new source commits. Unpublished help-center submodule pointers,
channel-sync changes and the unfinished voice-policy tail are excluded. Existing
PROD pricing, organization billing and enabled clinic AI modes are outside this
candidate.

## Independent cutovers

Prepare a reviewed combined deployment plan from the source runbooks before
changing an environment. Do not collapse the following gates into a code deploy.

1. Company replies: follow `script/onelink/WORKSPACE_SETTINGS.md`. Run the new
   maintenance code without switching the old application. Inspect
   `workspace_replies:preflight`; freeze old settings writers for the permitted
   migration. Conflicting texts require an explicit private `CONFIG_PATH` choice
   with the inspected digest. Never pick the first inbox or enable replies by
   default. Preflight must have no pending accounts before the new company
   readers, writers and UI are enabled. The old API cannot prepare these keys.
2. AI capabilities: use `captain:capabilities:plan` and `preflight` for the actual
   environment. The synthetic review matrix is not an inventory. Ready legacy
   rows still need explicit activation with the platform actor, matching digest
   and a ready plan under lock. The global preflight requires all persisted
   assistants migrated without blockers. Do not infer grants from prompt text,
   activate blocked plans, or treat the separate voice tail as completed.
3. AI usage: follow `script/onelink/ai-usage-cutover.md` for both backend and
   companion. Apply all three additive migrations in a permitted maintenance
   step, then batched historical prepare. Verify old Captain writers are drained
   before admitting new writers. Refresh old tabs/drafts, enable the new recovery
   cron, run preflight, and explicitly activate only after the real drain and
   index/cron checks. An environment flag is confirmation of that fact, not a
   bypass. Do not send a real test message without a separately agreed test.

The company, capabilities and metering gates need their own evidence and a
combined order that preserves each runbook's prerequisites. Do not write private
texts, tokens, patient data or raw environment snapshots into shared artifacts.

## Schema, schedule and rollback

The schema merge retains the existing billing objects and concurrent historical
delivery index. It adds migrations `20261102013000`, `20261102013100` and
`20261102013200`, all four metering/identity tables and the pending-usage index.
The schema version is `20261102013200`. The existing CPU-staggered and Billing
crons remain; the only new schedule entry is recovery at second 17 each minute.
Do not put the concurrent index migration in an outer DDL transaction.

After AI usage activation, rollback is pause and fix-forward with SQL identities,
events and pending preserved. Do not resume old direct billing over new windows
or roll back the active tables. Company app/UI rollback preserves retired inbox
columns, but later common-only edits require an explicit business choice. AI
capability rollback has its own digest/state guard; there is no generic safe
blanket data rollback.

Exact merged tests, independent review and browser checks are still required.
Live DEV needs the earlier review reservation transferred, the data gates above
and another exact-SHA acceptance. PROD additionally needs the owner's specific
approval, canonical release/eval gates and a concrete rollout/rollback plan.
