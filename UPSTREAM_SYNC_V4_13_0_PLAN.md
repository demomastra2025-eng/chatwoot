# Onelink Upstream Carry Plan To Chatwoot v4.13.0

## Current Baseline

- Base product branch: `onelink-main`
- Current packaged version in this fork: `4.12.1`
- Current upstream target: `v4.13.0`
- Current divergence against upstream target: about `61` local unique commits vs `86` upstream unique commits
- Local fork delta from `v4.12.1`: about `2496` changed files, `155451` insertions, `52203` deletions
- Upstream delta from `v4.12.1` to `v4.13.0`: `1017` changed files
- File overlap between local fork changes and upstream `v4.13.0` changes: `445` files
- Highest-overlap zones:
  - `app/javascript`
  - `config/locales`
  - `app/controllers`
  - `app/models`
  - `app/services`
  - `enterprise/app`

## Meaning

This is no longer a normal fork where a full upstream merge is the safest path.

For this repository, the most reliable route is:

1. carry `v4.13.0` in controlled batches,
2. cherry-pick safe upstream fixes first,
3. port medium-risk changes in themed clusters,
4. manually reconcile high-risk product areas,
5. only then decide whether the branch is close enough to be labeled as effectively on `v4.13.0`.

## Diff Audit Notes From Actual `v4.12.1..v4.13.0`

- Verified upstream carry surface: about `86` upstream unique commits, `1017` changed files, `445` overlapping files against local fork changes
- The real conflict hotspot is frontend/dashboard work:
  - `app/javascript/dashboard` alone accounts for about `330` of the `445` overlapping files
- Current Onelink-specific hotspots observed while checking local implementation:
  - `Telephony::CallSession` and `Voice::CallSessionSyncService` already act as the local voice source of truth
  - Captain custom tools already exist locally and are gated through current Onelink feature/runtime logic, not through upstream `response_bot -> custom_tools` reuse
  - `assignment_v2` is locally coupled to `advanced_assignment`, so default-enabling it is higher risk in Onelink than in upstream
  - widget first-message attribute/label queueing is still missing locally
  - the upload endpoint still fetches external URLs through direct `uri.open`
  - macros/automations already support `remove_assigned_team`, but not the explicit `remove_assigned_agent` action

These findings change the carry order in a few places:

- promote a few missing hardening fixes into early waves
- keep automation/macro semantics in a dedicated cluster instead of treating them as generic safe cherry-picks
- treat `assignment_v2` default enablement as a separate high-risk package

## Goal

Carry as much of `Chatwoot v4.13.0` as practical into `Onelink` while preserving Onelink-specific behavior and avoiding a destructive full rebase/remerge workflow.

## Non-Goals

- Do not run a blanket `merge upstream/v4.13.0` into `onelink-main`.
- Do not rebase active feature branches first.
- Do not start with translation-only sync.
- Do not force upstream product assumptions into Onelink without an explicit decision.
- Do not use generic self-hosted upgrade flows like `cwctl --upgrade` for production because this is a custom branch.

## Branching Model

Work only through a dedicated carry branch:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink fetch upstream --tags --prune
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink checkout onelink-main
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink pull --ff-only origin onelink-main
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink checkout -b sync/chatwoot-v4.13.0-carry
```

Do not work directly in `develop` or in an active delivery branch.

## Execution Strategy

Use five waves.

### Wave 0: Freeze and Inventory

Before any carry work:

- freeze non-critical product changes into `onelink-main`
- snapshot current production behavior and critical customer flows
- define the must-not-break list:
  - telephony bridge and Fonoster/Twilio voice flows
  - Captain / custom tool flows
  - assignment policies
  - onboarding / signup / account creation
  - API inbox / agent bot webhooks
  - WhatsApp custom behavior

Required outputs:

- green baseline branch from `onelink-main`
- list of critical regression scenarios
- one rollback tag or backup branch, for example `backup/pre-v4.13.0-carry`

### Wave 1: Safe Cherry-Picks First

These are the first candidates because they have zero or near-zero file overlap with fork-specific changes and mostly look like hardening / bugfix work.

Candidate batch A:

- `0012fa2c35` fix: align message trimming with configured maxLength
- `224b1f98b0` fix: handle ioerror in imap fetch
- `de0bd8e71b` fix(perf): disable tags counter cache to prevent label deadlocks
- `f2cb23d6e9` fix: handle Socket::ResolutionError in browser push notifications
- `0592cccca9` fix: prevent lost custom_attributes updates from concurrent jsonb writes
- `4c4b70da25` fix: Skip email rate limiting for self-hosted instances
- `4cce7f6ad8` fix(line): Use non-expiring URLs for image and video messages
- `cac7438fff` fix: Email Channel links are not working (backend)
- `d84ef4cfd6` fix(whatsapp): skip health check during reauthorization flow
- `65867b8b36` fix: exclude MutexApplicationJob::LockAcquisitionError from Sentry
- `72b8a31f2d` fix: handle users being stuck on is_creating billing flow
- `6f5ad8f372` fix: strip manually_managed_features from params in super admin account create

Candidate batch B:

- `97dae52841` fix: use committed model registry for RubyLLM
- `135be52431` feat: introduce last responding agent option to automation assign agent
- `45b6ea6b3f` feat: add automation condition to filter private notes
- `9efd554693` fix: resolve V2 capacity bypass in team assignment
- `48533e2a5d` fix: strip markdown hard-break backslashes from webhook payloads
- `d83beb2148` fix: include attachment extension/content_type in webhook payload

Candidate batch C:

- `3f9f054c43` fix: drop WhatsApp incoming messages from blocked contacts

Rules for Wave 1:

- cherry-pick in very small groups
- commit after each group
- run narrow tests after each group
- if a pick touches fork-specific code unexpectedly, stop and move it to Wave 2 or Wave 3
- if automation or macro UI/state conflicts appear around `135be52431` or `45b6ea6b3f`, move them to the dedicated automation cluster below instead of forcing them through Wave 1

Suggested first command pattern:

```bash
git cherry-pick -x 0012fa2c35 224b1f98b0 de0bd8e71b f2cb23d6e9 0592cccca9 4c4b70da25 4cce7f6ad8 cac7438fff d84ef4cfd6
```

Then verify:

```bash
git diff --check
bundle exec rspec spec/requests spec/controllers
pnpm test -- --runInBand
```

### Wave 2: Structured Medium-Risk Carry

These commits should be carried, but only in themed clusters because they touch shared runtime or frontend/editor surfaces.

#### Cluster 2A: Webhook and API payload improvements

- `127ac0a6b2` show backend error message on API channel creation failure
- `50d6ebaaca` dispatch `conversation_status_changed` to agent bots
- `b815eb9ce0` dispatch webhook event on agent bot assignment
- `f4d66566d0` include `changed_attributes` in `conversation_updated`
- `0b41d7f483` swagger operationId fix

Default plan:

- carry this cluster before any product-level webhook secret rollout
- verify external integrations against current webhook consumers

#### Cluster 2B: Article editor / help center quality-of-life

- `72c9e1775b` prevent article editor reset while typing
- `5d9d754961` auto-linkify URLs on paste
- `7b09b033ef` markdown tables in help center
- `a8c8b38f51` create article on title blur
- `bd14e96ed9` allow article create without content
- `42441dbd28` GuideJar embed support

Default plan:

- carry backend/editor correctness first
- keep slash commands, table UI, and resize handles for Wave 3 because they touch more customized frontend/editor files

#### Cluster 2C: Contact and conversation UX

- `64f6bfc811` inline edit support for contact info
- `98cf1ce9f6` limit bulk select to visible items
- `23786bcb52` mark conversation notifications as read on visit
- `b9f824b43b` unreadable dark mode select fix

Default plan:

- port individually, not as one large frontend lump
- verify dashboard flows touched by custom Onelink widgets

#### Cluster 2D: Widget / upload / automation hardening

- `b3d0af84c4` queue SDK-set conversation attributes and labels for first message
- `871f2f4d56` harden fetching on upload endpoint
- `722e68eecb` validate support_email format and handle parse errors in mailer
- `aee979ee0b` add explicit remove assignment actions to macros and automations

Default plan:

- carry these with local adaptation, not as blind cherry-picks
- verify widget first-message metadata, upload URL handling, reply mailer behavior, and macro/automation execution end-to-end

### Wave 3: High-Risk Product Packages

These are the changes that should be planned as mini-projects, not as routine cherry-picks.

#### Package 3A: Signed webhooks for API inboxes and agent bots

Primary upstream commit:

- `95463230cb` feat: sign webhooks for API channel and agentbots

Why high risk:

- touches controllers, models, policies, routes, jobs, views, audit models, migrations
- changes external integration contract by adding secret-based verification
- overlaps strongly with current Onelink integrations and custom API behavior

Default plan:

1. carry schema and backend support first
2. expose secret reset only after partner compatibility check
3. roll out as opt-in or dual-mode initially if current consumers assume unsigned payloads

#### Package 3B: Unified `Call` model

Primary upstream commit:

- `f422c83c26` feat: Add unified Call model for voice calling

Why high risk:

- Onelink already has `Telephony::CallSession`, bridge controllers, voice providers, conference management, and Fonoster integration
- there is a real risk of duplicating state models or splitting source of truth between `Call` and `Telephony::CallSession`

Default plan:

- do not cherry-pick blindly
- first design the relation between upstream `Call` and local `Telephony::CallSession`
- preferred options:
  - option A: keep `Telephony::CallSession` as source of truth and backport only analytics-safe pieces
  - option B: adopt upstream `Call` as canonical model and build compatibility sync from Onelink telephony stack

This package requires an explicit decision before implementation.

#### Package 3C: Captain Custom Tools v1 and related feature-flag changes

Primary upstream commits:

- `8daf6cf6cb` feat: captain custom tools v1
- `b4ce59eea8` reclaim `response_bot` flag for `custom_tools`
- `fbe3560b7a` add paywall and expose Custom Tools
- `5264de24b0` migrations for document auto-sync
- `00837019b5` display handoff message to customer in V2 flow
- `b7b6e67df7` localize AI summary to account language

Why high risk:

- Onelink already has Captain custom tool extensions and custom runtime code
- upstream changes rename/repurpose feature semantics in `config/features.yml`
- this can silently break plan gating, tool visibility, or runtime assumptions

Default plan:

1. diff current Onelink Captain implementation against these upstream commits
2. port backend model/service changes before frontend/sidebar/paywall changes
3. treat feature-flag migration separately from UI exposure

This package requires an explicit decision before implementation.

#### Package 3D: Signup verification flow

Primary upstream commit:

- `4f94ad4a75` feat: ensure signup verification

Why high risk:

- touches account creation, auth flow, route guards, sessions, and onboarding UX
- may conflict with Onelink account bootstrap, CRM-linked onboarding, or sales-assisted provisioning

Default plan:

- do not include in early carry waves
- confirm whether Onelink wants Chatwoot-style verify-before-dashboard behavior for all self-serve signups

#### Package 3E: Assignment V2 default enablement

Primary upstream commit:

- `f1da7b8afa` feat: enable assignment v2 by default for new accounts

Why high risk in Onelink:

- locally `assignment_v2` is coupled to `advanced_assignment`
- enabling it by default changes new-account behavior rather than only fixing an existing runtime bug
- it can widen the blast radius of assignment-policy UI and background jobs before we intentionally decide to do so

Default plan:

- do not auto-enable this during the main carry branch
- keep the `9efd554693` assignment bugfix independent from this decision
- revisit only after explicit product sign-off and assignment regression coverage

### Wave 4: Optional / Noisy / Late Carry

These should be done last, only after runtime code stabilizes.

#### Translation dumps

- `03c10ba147` chore: Update translations
- `8c0c0fd32c` chore: Update translations
- `45124c3b41` zh-TW translation improvements
- `aa2e8f99e4` zh/zh_CN translation fix
- `44a7a13117` Estonian settings language option

Reason:

- very large file overlap
- low business value relative to conflict surface
- can hide real code conflicts in noisy diffs

Recommended handling:

- take only targeted locale fixes needed by features actually carried
- defer full translation refresh until after the code carry is stable

#### Late carry candidates worth revisiting after runtime stabilization

- `4517c50227` support bulk select and delete for documents
- `5fd3d5e036` allow zero conversation limit capacity policy
- `699b12b1d3` block inline images in message signatures
- `288c1cb757` respect app direction for incoming email content
- `cc008951db` improve active child route matching logic in sidebar
- `b96bf41234` enable Participating tab for conversations

Reason:

- these bring user-facing value, but they touch frontend/editor/captain surfaces that already have heavy local divergence
- they should be decided after the core safety and integration batches land cleanly

#### Version bump

- `e123a4e500` bump version to `4.13.0`

Take this only after the branch is functionally ready.

## Required Verification Per Wave

### Minimum verification after every batch

```bash
git diff --check
bundle exec ruby -c config/routes.rb
bundle exec rails runner 'puts :ok'
```

### Backend / migration batches

```bash
bundle exec rails db:migrate
bundle exec rspec spec/models spec/requests spec/controllers
```

### Frontend / dashboard batches

```bash
pnpm install
pnpm eslint app/javascript/**/*.{js,vue}
pnpm test
```

### Integration-sensitive batches

Verify manually:

- API inbox webhook delivery
- agent bot webhook delivery
- WhatsApp flow
- telephony bridge routes
- Captain tool execution

## Stop Gates

Stop and ask for product direction if any of the following happens:

- an upstream change wants to replace `Telephony::CallSession` semantics
- webhook signing would break existing downstream consumers
- Captain feature-flag migration changes current plan entitlements or tool visibility
- signup verification blocks an existing onboarding path
- enabling `assignment_v2` by default would implicitly widen `advanced_assignment` in current Onelink plans
- article editor carry conflicts with locally customized reply/help-center UX
- widget metadata queueing or upload hardening would change current public integration behavior in a breaking way

## Questions Requiring User Decision

These are the main disputed points that should be answered before Wave 3 starts.

1. Voice model:
   - Do we want to adopt upstream `Call` as a new canonical entity, or keep `Telephony::CallSession` as canonical and only backport selective call-related improvements?
2. Signed webhooks:
   - Can we make agent bot and API inbox webhooks signed by default, or do we need backward-compatible dual mode for existing consumers?
3. Captain / custom tools:
   - Should upstream `custom_tools` feature semantics replace the current Onelink Captain gating, or should Onelink keep its current feature model and only backport safe runtime fixes?
4. Signup verification:
   - Should new self-serve signups be forced through email verification before they can enter the dashboard?
5. Assignment V2 default:
   - Do we want upstream behavior where new accounts get `assignment_v2` enabled by default even though Onelink currently couples that flag to `advanced_assignment` for eligible plans?

## Recommended Next Action

Start with Wave 1 only.

If Wave 1 lands cleanly, continue with:

1. webhook payload improvements,
2. article/help-center correctness fixes,
3. only then move into the decision-heavy packages.

This maximizes carried value early while keeping rollback simple.

## Complete `v4.13.0` Commit Inventory

This appendix is the working inventory for all upstream commits between `v4.12.1` and `v4.13.0`.

Important interpretation notes:

- `git cherry -v onelink-main v4.13.0` did not show exact patch-equivalent upstream commits already present in `onelink-main`
- because of that, every upstream commit below is still absent as a Git patch
- however, some behaviors are already partially covered locally through different Onelink implementations
- the categories below are therefore runtime-oriented, not only Git-history-oriented

### Category A: Safe Carry Now

These are the commits most aligned with current Onelink logic and code shape.

- `0012fa2c35` fix: align message trimming with configured maxLength
  - narrow bugfix with no meaningful local conflict surface
- `224b1f98b0` fix: handle ioerror in imap fetch
  - isolated mail-fetch hardening
- `de0bd8e71b` fix(perf): disable tags counter cache to prevent label deadlocks
  - backend safety/perf fix with low product coupling
- `f2cb23d6e9` fix: handle Socket::ResolutionError in browser push notifications
  - operational hardening
- `0592cccca9` fix: prevent lost custom_attributes updates from concurrent jsonb writes
  - correctness fix with clear value for Onelink
- `4c4b70da25` fix: Skip email rate limiting for self-hosted instances
  - backend behavior matches fork expectations
- `4cce7f6ad8` fix(line): Use non-expiring URLs for image and video messages
  - provider-specific delivery fix with low overlap
- `cac7438fff` fix: Email Channel links are not working (backend)
  - narrow backend repair
- `d84ef4cfd6` fix(whatsapp): skip health check during reauthorization flow
  - low-risk channel bugfix
- `65867b8b36` fix: exclude MutexApplicationJob::LockAcquisitionError from Sentry
  - observability noise reduction
- `72b8a31f2d` fix: handle users being stuck on is_creating billing flow
  - narrow billing guardrail
- `6f5ad8f372` fix: strip manually_managed_features from params in super admin account create
  - aligns with local enterprise account handling
- `97dae52841` fix: use committed model registry for RubyLLM
  - backend AI runtime hardening with no observed local conflict
- `d83beb2148` fix: Populate `extension` and include `content_type` in attachment webhook payload
  - payload enrichment that fits current integration direction
- `3f9f054c43` fix: drop WhatsApp incoming messages from blocked contacts
  - currently missing locally and clearly correct
- `441fe4db11` fix: scope external_url override to Instagram DM conversations only
  - narrow attachment behavior fix
- `0b41d7f483` docs(swagger): fix operationId typo `converation` -> `conversation`
  - safe API docs correctness fix
- `8824efe0e1` fix(sentry): syntaxError: No error message
  - small observability hardening
- `f13f3ba446` fix: log only on system api key failures
  - low-risk logging cleanup across LLM services

### Category B: Carry With Local Adaptation

These are useful changes that Onelink does not fully have yet, but they should be ported with local reconciliation instead of blind cherry-pick.

- `742c5cc1f4` feat(dialogflow): make language_code configurable instead of hardcoded
  - local Dialogflow still hardcodes `en-US`; good fix, but config and integration files have drifted
- `e4c3f0ac2f` feat: fallback on phone number to update lead
  - useful CRM fix, but should be verified against local CRM assumptions
- `23786bcb52` chore: mark conversation notifications as read on visit
  - useful UX improvement with dashboard overlap
- `4517c50227` feat: support bulk select and delete for documents
  - valuable for Captain docs, but touches customized Captain UI and store code
- `5d9d754961` chore(editor): Auto-linkify URLs immediately on paste
  - good editor UX fix with frontend overlap
- `127ac0a6b2` fix: show backend error message on API channel creation failure
  - useful API inbox ergonomics, but controller/UI files already diverged
- `9efd554693` fix: resolve V2 capacity bypass in team assignment
  - should be carried independently from the default-enable decision for `assignment_v2`
- `04acc16609` fix: skip pay call if invoice already paid after finalize
  - likely correct, but should be checked against local billing customizations
- `b9f824b43b` fix(ui): resolve unreadable select options in dark mode
  - useful small UI fix, but inside overlapping dashboard surface
- `42441dbd28` feat: add GuideJar embed support in HC
  - optional value, but help center surface needs local product review
- `7b09b033ef` fix: Markdown tables don't render properly in help centre
  - sensible help center correctness fix
- `b3d0af84c4` fix(widget): Queue SDK-set conversation attributes and labels for first message
  - local SDK exposes the calls already, but first-message queueing is still missing
- `b815eb9ce0` fix(agent-bot): Dispatch webhook event on agent bot assignment
  - ordinary webhooks are richer locally, but agent bot parity is still missing
- `f4d66566d0` fix(agent-bot): Include `changed_attributes` in conversation_updated webhook
  - locally covered for normal webhooks, not for agent bots
- `50d6ebaaca` fix(agent-bot): Dispatch `conversation_status_changed` event to agent bots
  - locally covered for normal webhooks, not for agent bots
- `871f2f4d56` fix: harden fetching on upload endpoint
  - current upload endpoint still uses direct `uri.open`; logic is right, port should be local-first
- `722e68eecb` fix: validate support_email format and handle parse errors in mailer
  - useful because Onelink relies on `support_email`, but account/email code has local differences
- `45b6ea6b3f` feat: add automation condition to filter private notes
  - good automation feature, but overlaps with local automation UI/state
- `a8c8b38f51` fix: create article on title blur instead of debounce
  - editor correctness improvement with overlap
- `288c1cb757` fix: Respect app direction for incoming email content
  - sensible email UI correctness fix in a touched component
- `72c9e1775b` fix: Prevent article editor from resetting content while typing
  - good bugfix, but editor area is high-overlap
- `64f6bfc811` feat: Inline edit support for contact info
  - useful contact UX improvement with local component overlap
- `cc008951db` fix(sidebar): improve active child route matching logic
  - small routing/UI correctness fix with moderate value
- `edd0fc98db` feat: Table support in article editor
  - potentially useful, but editor stack is customized
- `5eee331da3` feat: add slash command menu to article editor
  - same reason as above
- `98cf1ce9f6` fix(bulk-select): limit select-all to visible items; add secondary slot
  - useful UX fix, but overlapping conversation list UI
- `b5264a2560` feat: Adds the ability to resize the editor
  - likely useful, but reply/editor surfaces are customized
- `48533e2a5d` fix: strip markdown hard-break backslashes from webhook payloads
  - useful integration polish with some overlap in payload-related files
- `aee979ee0b` fix: add explicit remove assignment actions to macros and automations
  - local parity is partial: `remove_assigned_team` exists, `remove_assigned_agent` does not
- `135be52431` feat: Introduce last responding agent option to automation assign agent
  - good feature, but automation builder and execution code require reconciliation
- `bd14e96ed9` chore: allow article to create without content
  - sensible help center authoring behavior, but should be carried with the editor cluster
- `b96bf41234` chore: Enable Participating tab for conversations
  - local strings already exist, but full behavior should be verified before carry

### Category C: Useful Upstream Work, But Do Not Carry Blindly Now

These are the commits where the product semantics or local architecture diverge enough that carrying them now would be unsafe.

- `4381be5f3e` feat: disable helpcenter on hacker plans
  - upstream billing-plan semantics do not map cleanly to Onelink product logic
- `7651c18b48` feat: firecrawl branding api [UPM-15]
  - new product direction, not an upstream correctness fix
- `b4ce59eea8` feat: reclaim response_bot flag for custom_tools
  - conflicts with current Onelink Captain feature model
- `1987ac3d97` fix: remove bulk_auto_assignment_job cron schedule
  - tied to upstream assignment rollout; not safe while local assignment strategy still mixes old and new flows
- `b4b5de9b46` fix: conservative hand_off prompt on auto-resolution
  - Captain prompt surface already diverged locally
- `211fb1102d` chore: rotate oauth password if unconfirmed
  - belongs with signup/auth flow decisions, not with safe carry
- `8daf6cf6cb` feat: captain custom tools v1
  - Onelink already has custom tools, but through different runtime and gating assumptions
- `95463230cb` feat: sign webhooks for API channel and agentbots
  - high-value change, but changes external integration contract
- `118270d2e8` fix(agent-bot): Update listener spec to match signed webhook arguments
  - follow-up to signed webhooks; only relevant after the signing decision
- `fbe3560b7a` feat(captain): Add paywall and expose Custom Tools
  - tightly coupled to upstream feature-flag and plan semantics
- `4f94ad4a75` feat: ensure signup verification
  - changes onboarding/auth behavior and needs product sign-off
- `e5107604a0` feat: account enrichment using context.dev [UPM-27]
  - not a safe parity carry; it is product expansion
- `699b12b1d3` fix: Block inline images in message signatures
  - upstream policy conflicts with current Onelink product messaging that inline images are supported
- `00837019b5` fix(captain): display handoff message to customer in V2 flow
  - Captain V2 flow differs locally and should not be patched blindly
- `f1da7b8afa` feat: enable assignment v2 by default for new accounts
  - high risk because local `assignment_v2` is coupled to `advanced_assignment`
- `f422c83c26` feat: Add unified Call model for voice calling
  - conflicts with local `Telephony::CallSession` source of truth
- `b7b6e67df7` fix(captain): localize AI summary to account language
  - locally desirable, but should move with a Captain-specific reconciliation package
- `5264de24b0` feat: migrations for document auto-sync [AI-141]
  - document/captain data model change should be handled only inside the broader Captain package
- `5fd3d5e036` feat: allow zero conversation limit capacity policy
  - tied to local assignment/capacity semantics and should be evaluated after assignment decisions

### Category D: Structural, Noise, Translation, Or Low-Value Carry

These commits are not the right early target for the carry branch.

- `ecc66e064d` Merge branch 'release/4.12.1' into develop
  - structural upstream merge commit
- `e0e321b8e2` fix: Annotaterb model annotation incomplete migration
  - repository maintenance, not product behavior
- `d9e732c005` chore(v5): update priority icons
  - low-value asset refresh
- `2b296c06fb` chore(security): ignore CVE-2026-33658 for Chatwoot storage defaults
  - upstream maintenance/config decision with low carry value here
- `44a7a13117` fix: Add Estonian to settings language options
  - locale-only
- `5de7ae492c` fix: html/body background not applied in appearance mode
  - only worth revisiting if the exact bug is reproduced locally
- `8c0c0fd32c` chore: Update translations
  - translation dump
- `45124c3b41` fix(i18n): improve zh-TW translation coverage and quality
  - translation-only
- `42163946eb` fix: Ignore RoutingError in New Relic error reporting
  - immediately reverted upstream
- `3190b29fe9` fix(revert): "fix: Ignore RoutingError in New Relic error reporting (#14030)"
  - revert of the previous change
- `8e5d4f4d23` chore(deps): bump axios from 1.13.6 to 1.15.0
  - dependency bump without specific carry value by itself
- `aa2e8f99e4` fix(i18n): correct zh/zh_CN conversation assignment message translations
  - translation-only
- `03c10ba147` chore: Update translations
  - translation dump
- `e123a4e500` Bump version to 4.13.0
  - take only after functional carry is complete
- `88ffa329eb` Merge branch 'release/4.13.0'
  - structural upstream merge commit
- `b9b5a18767` revert: html background for widget
  - follow-up to the appearance-only UI pair above; not useful by itself

### Missing-But-Partially-Covered Notes

These are the most important places where Onelink already has some of the behavior, but not the exact upstream parity yet.

- `50d6ebaaca` and `f4d66566d0`
  - `WebhookListener` already emits `conversation_status_changed` and `changed_attributes`, but `AgentBotListener` still lacks the equivalent upstream parity
- `aee979ee0b`
  - local macros already support `remove_assigned_team`, but not `remove_assigned_agent`
- `b3d0af84c4`
  - local SDK already exposes `setConversationCustomAttributes` and `setLabel`, but the first-message queueing behavior is missing
- `95463230cb`
  - regular account webhooks already support secrets, but API inbox and agent bot secret lifecycle is missing
- `8daf6cf6cb`, `b4ce59eea8`, `fbe3560b7a`, `5264de24b0`, `00837019b5`, `b7b6e67df7`
  - Captain custom tool and handoff behavior already exists locally, but through different architecture and feature semantics
- `f1da7b8afa`, `1987ac3d97`, `5fd3d5e036`, `9efd554693`
  - assignment v2 and advanced assignment already exist locally, but upstream defaults and job assumptions do not map cleanly
- `742c5cc1f4`
  - Dialogflow region support exists, but message language is still hardcoded

### Practical Reading Order For Implementation

If this appendix is used as the actual carry checklist, the recommended order is:

1. Category A first
2. the operational subset of Category B:
   - `127ac0a6b2`
   - `50d6ebaaca`
   - `b815eb9ce0`
   - `f4d66566d0`
   - `b3d0af84c4`
   - `871f2f4d56`
   - `722e68eecb`
   - `aee979ee0b`
3. the editor/contact UX subset of Category B
4. only then the Category C packages after explicit decisions
