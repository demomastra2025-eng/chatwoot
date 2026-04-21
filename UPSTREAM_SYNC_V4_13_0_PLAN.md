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

Rules for Wave 1:

- cherry-pick in very small groups
- commit after each group
- run narrow tests after each group
- if a pick touches fork-specific code unexpectedly, stop and move it to Wave 2 or Wave 3

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
- article editor carry conflicts with locally customized reply/help-center UX

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
   - Do we want upstream behavior where new accounts get `assignment_v2` enabled by default?

## Recommended Next Action

Start with Wave 1 only.

If Wave 1 lands cleanly, continue with:

1. webhook payload improvements,
2. article/help-center correctness fixes,
3. only then move into the decision-heavy packages.

This maximizes carried value early while keeping rollback simple.
