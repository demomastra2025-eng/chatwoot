# Onelink Selective Carry From Chatwoot v4.13.0

Status date: 2026-04-26
Worktree: `/Users/akhanbakhitov/Documents/zeroprompt/onelink-sync-v4.13.0-carry`
Branch: `sync/chatwoot-v4.13.0-carry`

## Principle

Onelink is the source of truth. Chatwoot `v4.13.0` is used as a fix and idea source, not as a branch to merge blindly.

Carry rule:

- If upstream and Onelink disagree on product logic, runtime architecture, or data ownership, keep the Onelink implementation as canonical.
- Apply directly when the upstream code matches Onelink architecture and cases.
- Apply with adaptation when the fix is correct but Onelink has local UX/runtime/product differences.
- Do not apply when the upstream change changes Onelink product semantics, replaces local architecture, or creates integration risk.
- Ask for a product decision only on true dilemmas.

## Accepted Decisions

These decisions were accepted on 2026-04-26 and close the previous open product questions:

- Voice calls: keep `Telephony::CallSession` as the canonical Onelink call entity. Do not add upstream `Call` / `calls`; only borrow lifecycle, status normalization, message-linking, and analytics ideas into the existing telephony model when useful.
- Captain custom tools: keep current Onelink runtime and access model. Do not carry upstream `response_bot -> custom_tools` entitlement migration, paywall semantics, or plan exposure changes in this branch.
- Assignment: keep `assignment_v2` disabled by default for new accounts. Preserve Onelink auto-assignment behavior for existing enabled inboxes, including inboxes without `assignment_policy`; carry upstream capacity/policy fixes only where they do not replace that behavior.
- Signup enrichment: defer Context.dev / Firecrawl account enrichment. Basic deterministic brand/social parsing can be reconsidered later as a separate onboarding feature.
- Signup verification: do not enforce a strict verify-before-dashboard policy in this carry. Keep signup flows compatible with current Onelink self-serve, API-only, and partner onboarding behavior.
- Versioning: do not bump Onelink to plain `4.13.0`. This is a selective carry branch, not full upstream compatibility.

## Applied

### Safe / Direct Or Near-Direct

- `0012fa2c35` message trimming respects configured max length.
- `224b1f98b0` IMAP fetch handles `IOError`.
- `de0bd8e71b` disables tags counter cache to avoid label deadlocks.
- `f2cb23d6e9` browser push handles `Socket::ResolutionError`.
- `0592cccca9` prevents lost concurrent `custom_attributes` writes.
- `4c4b70da25` skips email rate limiting for self-hosted instances.
- `4cce7f6ad8` LINE image/video messages use non-expiring URLs.
- `cac7438fff` fixes email channel links backend behavior.
- `d84ef4cfd6` skips WhatsApp health check during reauthorization.
- `65867b8b36` excludes Sidekiq mutex lock acquisition noise from Sentry.
- `72b8a31f2d` handles users stuck in billing `is_creating`.
- `6f5ad8f372` strips `manually_managed_features` on super admin account create.
- `97dae52841` uses committed RubyLLM model registry.
- `3f9f054c43` drops WhatsApp incoming messages from blocked contacts.
- `04acc16609` skips invoice pay call if already paid after finalize.
- `e4c3f0ac2f` falls back to phone number when updating leads.
- `2b296c06fb` CVE ignore for upstream storage defaults.
- `8e5d4f4d23` Axios security bump to `1.15.0`.

### API / Webhooks / Integrations

- `127ac0a6b2` API channel creation surfaces backend error messages.
- `95463230cb` signs API channel and agent bot webhooks.
- `118270d2e8` updates agent bot listener specs for signed webhook arguments.
- `b815eb9ce0` dispatches webhook event on agent bot assignment.
- `f4d66566d0` includes `changed_attributes` in agent bot `conversation_updated`.
- `50d6ebaaca` dispatches `conversation_status_changed` to agent bots.
- `d83beb2148` populates attachment `extension` and includes `content_type`.
- `441fe4db11` scopes Instagram `external_url` override only to Instagram DM conversations.
- `48533e2a5d` strips markdown hard-break backslashes from webhook payloads.
- `871f2f4d56` upload fetching hardening is already covered in the branch.
- `722e68eecb` validates `support_email` and handles mailer parse errors.
- `288c1cb757` respects app direction for incoming email content.

### Help Center / Editor / Docs UX

- `4517c50227` bulk select and delete for Captain documents.
- `5d9d754961` auto-linkifies URLs on paste.
- `7b09b033ef` renders markdown tables in help center.
- `42441dbd28` GuideJar embed support in help center.
- `bd14e96ed9`, `a8c8b38f51`, `72c9e1775b` safe article editor cluster: draft creation on title blur, empty content for drafts, no editor reset while typing.
- `edd0fc98db` table support in article editor.
- `5eee331da3` slash command menu in article editor.
- `b5264a2560` resizable reply/editor UI.

### Dashboard / Conversation UX

- `23786bcb52` marks conversation notifications as read on visit.
- `b9f824b43b` fixes unreadable select options in dark mode.
- `cc008951db` improves active child route matching in sidebar.
- `64f6bfc811` inline edit support for contact info.
- `98cf1ce9f6` bulk select all limited to visible items plus secondary slot.
- `b96bf41234` enables Participating conversations tab.
- `b3d0af84c4` queues SDK-set conversation attributes and labels for the first widget message.
- `d9e732c005` priority icon refresh.
- `5de7ae492c` and `b9b5a18767` appearance background pair applied with upstream revert semantics.

### Automation / Assignment

- `9efd554693` fixes V2 capacity bypass in team assignment.
- `5fd3d5e036` allows zero conversation limit capacity policy.
- `1987ac3d97` removes old bulk auto-assignment cron and job.
- `aee979ee0b` adds explicit remove assignment actions to macros and automations.
- `135be52431` adds last responding agent option to automation assign agent.
- `45b6ea6b3f` adds automation condition for private notes.

### Auth / Signup / Security

- `211fb1102d` rotates OAuth password if user is unconfirmed.
- `699b12b1d3` blocks inline images in message signatures.
- `f13f3ba446` logs only system API key LLM failures to exception tracker.
- `8824efe0e1` Sentry locale guard was already equivalent in code and was skipped as no-op.

### Captain / AI

- `742c5cc1f4` Dialogflow `language_code` configurability.
- `b7b6e67df7` AI summary localized to account language.
- `b4b5de9b46` conservative handoff prompt fix.
- `8daf6cf6cb` custom tools v1 runtime carried selectively: V1 assistant runtime now wires existing Onelink custom tools.
- `00837019b5` V2 handoff message fix carried with Onelink buffer-state and `preserve_waiting_since`.
- `5264de24b0` carried only the safe `captain_assistant_responses.edited` part.

## Applied With Onelink Adaptation

- Auto-assignment cron/job changes are adapted after the feature-branch audit: remove the stale upstream-style `bulk_auto_assignment_job` Sidekiq cron entry to avoid duplicate jobs, but keep Onelink's no-policy auto-assignment sweep by having `AutoAssignment::PeriodicAssignmentJob` process `enable_auto_assignment` inboxes without requiring `assignment_policy`.
- Custom tools runtime keeps Onelink feature/gating behavior and does not apply upstream `response_bot -> custom_tools` paywall semantics.
- Document auto-sync does not add upstream `captain_documents.sync_status` columns because Onelink already uses Firecrawl metadata-backed sync state.
- Resizable editor keeps local editor sizing and reply-box behavior.
- Priority icon component avoids upstream dynamic i18n key warning.
- Axios lockfile was regenerated minimally: `axios 1.13.6 -> 1.15.0`, `proxy-from-env 1.1.0 -> 2.1.0`.

## Already Covered / No-Op

- `8824efe0e1` Sentry empty locale guard is already present.
- `d83beb2148` attachment extension/content type behavior is already present.
- `0b41d7f483` Swagger typo is already covered.
- `127ac0a6b2`, `742c5cc1f4`, multiple webhook and help-center commits show as non-equivalent patch IDs because Onelink carries adapted implementations.

## Not Applied

### Needs Product Decision

- `f1da7b8afa` enable `assignment_v2` by default for new accounts.
  - Reason: changes new-account behavior and is coupled to Onelink `advanced_assignment`.
- `f422c83c26` unified upstream `Call` model.
  - Reason: Onelink already has `Telephony::CallSession` / voice provider source of truth.
- `b4ce59eea8` reclaim `response_bot` flag for `custom_tools`.
  - Reason: changes entitlement semantics and can disable/alter existing custom tools access.
- `fbe3560b7a` custom tools paywall / UI exposure.
  - Reason: product monetization decision, not a safe bugfix.
- `7651c18b48` Firecrawl branding API.
  - Reason: onboarding/product expansion, not a correctness fix.
- `e5107604a0` Context.dev account enrichment.
  - Reason: adds external dependency and signup/onboarding background behavior.

### Intentionally Skipped

- `4381be5f3e` disable help center on hacker plans.
  - Reason: upstream billing-plan semantics do not map cleanly to Onelink.
- `44a7a13117` Estonian language option.
  - Reason: Onelink active product locales are not being expanded in this carry.
- `8c0c0fd32c`, `45124c3b41`, `aa2e8f99e4`, `03c10ba147`.
  - Reason: translation dumps/noisy i18n updates; take only keys required by carried features.
- `e0e321b8e2` Annotaterb annotation maintenance.
  - Reason: non-functional repo maintenance.
- `42163946eb` and `3190b29fe9` NewRelic ignore + immediate revert.
  - Reason: upstream net no-op.
- `4f94ad4a75` signup verification flow.
  - Reason: accepted decision is to avoid strict verify-before-dashboard behavior in this carry and preserve current Onelink self-serve, API-only, and partner onboarding flows.
- `e123a4e500` version bump to `4.13.0`.
  - Reason: this is a selective carry branch, not full upstream `4.13.0` compatibility.
- `5264de24b0` document DB sync columns.
  - Reason: conflicts with Onelink Firecrawl metadata sync model.

## Decision Audit Status

- Upstream `Call` / `calls` is not present; Onelink keeps `Telephony::CallSession`.
- Upstream `response_bot -> custom_tools` entitlement migration and Custom Tools paywall are not present.
- `assignment_v2` remains disabled by default in `config/features.yml`.
- `AutoAssignment::PeriodicAssignmentJob` preserves Onelink's sweep for `enable_auto_assignment` inboxes without requiring `assignment_policy`.
- Context.dev / Firecrawl account enrichment is not present.
- Strict signup verification was removed after the accepted decision; current signup flow keeps auth headers and dashboard redirect behavior.
- Version files remain Onelink-specific and are not bumped to plain `4.13.0`.

## Finalization Record

This branch intentionally carries the useful Chatwoot `v4.13.0` fixes and selected feature improvements without claiming full upstream `4.13.0` compatibility.

Important final commit before this runbook was added:

- `44fdd93403` records the accepted product decisions and removes the strict signup verification flow that had been carried earlier.

Final branch policy:

- publish the sync branch to `origin`;
- merge into `onelink-main` only after acceptance checks;
- reconcile `feature/workspace-20260327` after `onelink-main`, because that active branch contains newer telephony/Fonoster work;
- do not merge this carry straight into the active feature branch as the first integration step.

## Reusable Runbook For `v4.14+`

Use this process for the next Chatwoot release carry, for example `v4.14.0`.

### 1. Create A Dedicated Sync Worktree

- Start from `onelink-main`, not from `develop` and not from an active feature branch.
- Fetch upstream tags first.
- Use a dedicated branch and worktree, for example:
  - `sync/chatwoot-v4.14.0-carry`
  - `../onelink-sync-v4.14.0-carry`

### 2. Measure Before Carrying

Before cherry-picking or manually porting code, produce the same inventory:

- upstream commit list between the previous accepted upstream tag and the target tag;
- upstream changed files;
- local fork changed files from the previous upstream base to `onelink-main`;
- overlapping files between upstream and local fork changes;
- hotspot directories, especially `app/javascript/dashboard`, `enterprise`, `app/services`, `config`, `db/migrate`, and provider integrations.

Do not use the overlap count as an automatic yes/no decision. Use it to choose wave size and risk level.

### 3. Classify Every Upstream Commit

Every upstream commit should land in one of these buckets:

- Safe direct or near-direct carry: narrow bugfix, low product coupling, low local overlap.
- Carry with Onelink adaptation: useful behavior, but local UX/runtime/data model differs.
- Already covered or no-op: current Onelink code already has equivalent behavior.
- Needs product decision: changes product semantics, monetization, onboarding, defaults, external dependencies, or core architecture.
- Intentionally skipped: noisy translation dumps, version bumps, maintenance-only updates, or upstream assumptions that do not fit Onelink.

Keep this classification in the plan file before or while carrying, not only in chat.

### 4. Default Product Decisions Unless Reopened

These defaults should carry forward to `v4.14+` unless there is an explicit new product decision:

- General: in any conflict between upstream and Onelink behavior, treat Onelink as canonical and adapt only the useful fix idea.
- Voice: `Telephony::CallSession` remains canonical. Do not add a parallel upstream `Call` model unless Onelink intentionally designs a compatibility layer.
- Captain custom tools: keep Onelink runtime and access semantics. Do not adopt upstream paywall or `response_bot -> custom_tools` entitlement migration by default.
- Assignment: keep `assignment_v2` default behavior conservative and preserve existing Onelink auto-assignment behavior for enabled inboxes, including the no-policy path. Carry assignment bugfixes separately from new-account default enablement.
- Signup enrichment: do not add Context.dev, Firecrawl, or similar external enrichment during signup without a separate onboarding decision.
- Signup verification: do not enforce strict verify-before-dashboard behavior unless current Onelink onboarding policy changes.
- Versioning: do not bump to a plain upstream version string unless the branch is accepted as full upstream-compatible, which selective carry branches normally are not.

### 5. Carry In Waves

Recommended wave order:

1. Backend safety fixes and provider hardening.
2. API, webhook, and integration parity fixes.
3. Help center/editor/dashboard UX fixes, split by subsystem.
4. Assignment and automation fixes, separated from default-enable or plan semantics.
5. Captain runtime fixes, separated from paywall, entitlement, and data-model changes.
6. Product-decision packages only after explicit acceptance.
7. Version bump and translation dumps last, usually skipped for selective carries.

Commit after coherent batches. Keep commits small enough to revert without losing unrelated carried behavior.

### 6. Stop And Ask

Stop carrying and ask for direction when upstream changes any of these:

- voice/call source of truth;
- Captain tool access, monetization, or feature flags;
- assignment defaults for new accounts;
- signup/onboarding access rules;
- external enrichment or data-sharing during signup;
- webhook signing or external integration contracts;
- account billing/plan semantics;
- database model replacement rather than additive bugfixes.

### 7. Final Audit Checklist

Before publishing a carry branch, explicitly verify:

- no upstream `Call` / `calls` model was introduced unless intentionally accepted;
- `config/features.yml` did not flip sensitive defaults such as `assignment_v2`;
- no upstream custom-tools paywall or entitlement migration slipped in;
- no external signup enrichment was added;
- no strict signup verification flow was added unintentionally;
- version files were not bumped to a plain upstream version by inertia;
- migrations match accepted behavior and do not introduce skipped product packages;
- the plan file has `Applied`, `Applied With Onelink Adaptation`, `Already Covered / No-Op`, `Not Applied`, `Decision Audit Status`, and `Verification Notes` sections.

### 8. Verification And Publication

Minimum verification before pushing:

- `git diff --check`;
- Ruby syntax checks for touched backend/config files;
- JSON/YAML parse checks for touched locale/config files;
- ESLint for touched frontend clusters;
- targeted RSpec for touched backend behavior when PostgreSQL is available.

If PostgreSQL is unavailable, record the exact blocker and do not describe RSpec as passed.

Publication order:

1. push `sync/chatwoot-vX.Y.Z-carry` to `origin`;
2. review/merge into `onelink-main`;
3. only then reconcile active feature branches such as `feature/workspace-20260327`;
4. avoid direct sync-branch merges into unrelated feature branches before `onelink-main` accepts the carry.

## Verification Notes

Passed in this worktree:

- Ruby syntax checks for touched backend files.
- `git diff --check` for each batch.
- ESLint for touched frontend clusters where applicable.
- RuboCop for the latest Captain changed files.
- JSON parse checks for touched signup locale files.
- YAML parse check for `config/schedule.yml`.
- Conflict-marker scans for touched batches.
- `POSTGRES_PASSWORD=postgres bundle exec rspec spec/controllers/api/v1/accounts_controller_spec.rb` passed after Docker Compose `postgres` / `redis` services were running.
  - Result: `20 examples, 0 failures`.

## Remaining Acceptance Work

1. Re-check final branch diff before merge into `onelink-main`.
2. After merge into `onelink-main`, reconcile the active `feature/workspace-20260327` branch separately because it contains newer telephony work.
