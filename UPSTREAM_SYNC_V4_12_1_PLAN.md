# Onelink Upstream Sync Plan To Chatwoot v4.12.1

## Current Baseline

- Project base branch: `onelink-main`
- Current upstream target: `v4.12.1`
- Current upstream base already merged into `onelink-main`: `v4.11.1`
- Exact shared base commit: `a08125e283b8e15b84b5073def1e785137b059ba`
- Meaning: `onelink-main` is still on the `4.11.1` Chatwoot line, not on `4.12.x`
- Gap from `onelink-main` to `v4.12.1`: `18` local commits vs `144` upstream commits
- Current working feature branch `feature/whatsapp-web-dashboard-suite` must not be updated directly from upstream first

## Goal

Move the fork to `Chatwoot v4.12.1` by making `v4.12.1` the new core base, then reapplying and validating Onelink-specific behavior on top of it.

The correct mental model is:

1. `Chatwoot v4.12.1` becomes the new base.
2. Onelink-specific functionality is adapted on top of that base.
3. Feature branches are updated only after `onelink-main` is stabilized.

## What Must Be Preserved

These areas are part of the fork and must be intentionally carried forward if still needed:

- Onelink scheduling surface
- MacroCRM integration
- Medelement integration and sync flows
- WhatsApp Web runtime and dashboard flows
- Onelink docs/skill workflow and branding decisions
- Any account/domain-specific behavior that is intentionally different from Chatwoot core

## What Must Be Taken From Upstream

These should generally be accepted from `v4.12.1` first, then adapted only where needed:

- security and dependency updates
- core email/inbox/oauth behavior
- core conversation, message, contact, company, widget, portal, and help center fixes
- core Captain/AI fixes that affect shared product behavior
- routing and feature flag changes required by upstream runtime
- package and gem lock updates required for supported dependency graph

## Do Not Do This

- Do not merge upstream into `feature/whatsapp-web-dashboard-suite` first.
- Do not use `develop` as the base branch for sync.
- Do not pull random upstream feature branches.
- Do not treat old fork behavior as the default winner in conflicts.
- Do not force-push `onelink-main`.

## High-Level Sequence

1. Prepare local repo and dependencies.
2. Create dedicated sync branch from `onelink-main`.
3. Merge upstream tag `v4.12.1` into the sync branch.
4. Resolve conflicts in a strict order.
5. Boot and verify the app on the sync branch.
6. Merge sync branch back into `onelink-main`.
7. Rebase or merge active feature branches onto the updated `onelink-main`.

## Stage 0: Preparation

Work in the main app repo:

- repo: `/Users/akhanbakhitov/Documents/zeroprompt/onelink`
- writable remote: `origin`
- upstream remote: `upstream`

Run:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink fetch origin --prune
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink fetch upstream --tags --prune
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink remote -v
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink tag --list 'v4.12*' --sort=-version:refname
```

Expected result:

- `origin` points to the Onelink fork over SSH
- `upstream` points to `https://github.com/chatwoot/chatwoot.git`
- target tag `v4.12.1` is available locally

Before sync, confirm local branches are safe:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink status --short --branch
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink checkout onelink-main
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink pull --ff-only origin onelink-main
```

If `onelink-main` has local unstaged changes, stop and clean that up first. Untracked files like `.eslintcache` are not important, but they should not be confused with real source changes.

## Stage 1: Create Sync Branch

Create a dedicated upstream intake branch:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink checkout -b sync/chatwoot-v4.12.1 onelink-main
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink push -u origin sync/chatwoot-v4.12.1
```

Why:

- this isolates upstream intake work
- this keeps `onelink-main` protected while conflicts are being resolved
- this gives a stable branch for review and testing

## Stage 2: Merge Upstream Release

Merge the release tag, not `upstream/master` and not `upstream/develop`:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink merge v4.12.1
```

If Git stops on conflicts, do not panic and do not abort immediately. The fork is expected to conflict because both sides changed overlapping runtime surfaces.

At this point, inspect:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink status --short
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink diff --name-only --diff-filter=U
```

## Stage 3: Resolve Conflicts In This Exact Order

Do not resolve files randomly. Resolve by dependency and runtime importance.

### 3.1 Dependency And Runtime Control Files

Resolve first:

- `Gemfile.lock`
- `package.json`
- `pnpm-lock.yaml`
- `config/routes.rb`
- `config/features.yml`

Rule:

- upstream wins on dependency graph unless a fork-only dependency is still required
- if a fork-only package or gem is still needed, re-add it intentionally after accepting upstream base changes
- do not keep the old lockfiles just because they were local

Why this comes first:

- later file behavior depends on the runtime and package graph
- if lockfiles are wrong, verification will fail for misleading reasons

### 3.2 Email, Inbox, OAuth, SMTP

Resolve next:

- `app/controllers/api/v1/accounts/inboxes_controller.rb`
- `app/mailers/conversation_reply_mailer.rb`
- `app/mailers/conversation_reply_mailer_helper.rb`
- inbox settings frontend under `app/javascript/dashboard/routes/dashboard/settings/inbox/`
- email-related helper/service/config files added by either side

Rule:

- accept upstream `4.12.1` core email and OAuth behavior as the base
- reapply Onelink-specific SMTP fixes only if they are still necessary after the merge
- compare current Onelink SMTP patch against upstream `4.12.1` email changes before keeping both

Concrete review questions:

1. Does upstream already cover the original bug?
2. Does the Onelink SMTP patch still patch a real gap in `mail 2.8.1` and `net-smtp 0.3.4`?
3. Are Onelink inbox settings UI changes compatible with upstream settings payloads?

### 3.3 Shared Dashboard Components

Resolve next:

- `app/javascript/dashboard/components-next/message/`
- `app/javascript/dashboard/components-next/sidebar/`
- `app/javascript/dashboard/components-next/Editor/`
- `app/javascript/dashboard/components/widgets/WootWriter/`
- `app/javascript/dashboard/routes/dashboard/settings/`
- `app/javascript/dashboard/routes/dashboard/contacts/`
- `app/javascript/dashboard/routes/dashboard/companies/`

Rule:

- upstream wins for shared component structure and upstream bug fixes
- Onelink-specific flows should be re-layered on top instead of restoring old files wholesale
- do not blindly keep the older Onelink copy of a shared component if upstream changed the same flow for bugfixes or supported package updates

### 3.4 Core Models, Controllers, Services

Resolve next:

- `app/models/account.rb`
- `app/models/conversation.rb`
- `app/models/message.rb`
- `app/models/user.rb`
- `app/controllers/api/v1/accounts/contacts_controller.rb`
- `app/controllers/api/v1/accounts/conversations_controller.rb`
- `app/controllers/api/v1/accounts/articles_controller.rb`
- `app/controllers/api/v1/accounts/categories_controller.rb`
- `app/controllers/api/v1/accounts/integrations/linear_controller.rb`
- overlapping service files under `app/services/`

Rule:

- upstream wins on shared Chatwoot semantics
- preserve only clearly intentional Onelink behavior
- if a fork customization can move into a separate concern/service/extension point, do that instead of reopening upstream logic inline

### 3.5 Fork-Only Product Surfaces

Resolve after core is stable:

- scheduling controllers and frontend
- MacroCRM files
- Medelement files
- WhatsApp Web runtime files
- Onelink-specific integrations and dashboard screens

Rule:

- these are not expected to exist upstream, so carry them forward deliberately
- if upstream introduced nearby core changes, adapt the fork files to the new API contracts and UI patterns
- do not reintroduce removed assumptions from `v4.11.1` if upstream `v4.12.1` changed the underlying data or flow

## Stage 4: Practical Conflict Strategy

For each conflicting file:

1. Start from the upstream `v4.12.1` version.
2. Re-read the local Onelink diff for that file.
3. Keep only the Onelink-specific behavior that is still required.
4. Re-run a narrow verification for that surface.

Useful commands:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink checkout --theirs path/to/file
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink checkout --ours path/to/file
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink show v4.12.1:path/to/file
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink show onelink-main:path/to/file
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink diff onelink-main..sync/chatwoot-v4.12.1 -- path/to/file
```

Recommended interpretation:

- `theirs` = upstream `v4.12.1`
- `ours` = current Onelink sync branch state descended from `onelink-main`

## Stage 5: Verification Before Commit

After conflicts are resolved, run verification in layers.

### 5.1 Install And Prepare

```bash
cd /Users/akhanbakhitov/Documents/zeroprompt/onelink
eval "$(rbenv init - zsh)"
bundle install
pnpm install
bundle exec rails db:migrate
```

If the local database is messy or schema diverged too much:

```bash
bundle exec rails db:chatwoot_prepare
```

### 5.2 Backend Smoke Checks

Run narrow specs first:

```bash
bundle exec rspec spec/mailers/conversation_reply_mailer_spec.rb
bundle exec rspec spec/controllers/api/v1/accounts/inboxes_controller_spec.rb
bundle exec rspec spec/controllers/api/v1/accounts/conversations_controller_spec.rb
bundle exec rspec spec/models/account_spec.rb
bundle exec rspec spec/models/conversation_spec.rb
```

Then run integration-specific specs if the files were touched:

```bash
bundle exec rspec spec/lib/linear_spec.rb
bundle exec rspec spec/jobs/webhook_job_spec.rb
bundle exec rspec spec/mailers/conversation_reply_mailer_spec.rb
```

### 5.3 Frontend And Runtime Smoke Checks

```bash
pnpm dev:lite
```

Verify manually:

- dashboard loads
- inbox settings page opens
- SMTP and IMAP settings forms render
- contact and company pages load
- conversation list and message panel render
- Captain pages still mount
- help center and widget-related settings do not hard-fail

### 5.4 API And Schema Checks

If routes/controllers/swagger changed:

```bash
bundle exec rake swagger:build
```

Check:

- `config/routes.rb`
- `swagger/`
- `db/schema.rb`

## Stage 6: Commit The Sync Branch

When the sync branch is stable:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink status --short
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink add .
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink commit -m "sync: merge chatwoot v4.12.1 into onelink"
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink push origin sync/chatwoot-v4.12.1
```

Before merging back, record:

- what upstream changes were accepted as-is
- what Onelink patches were preserved
- what was dropped because upstream replaced it
- what still needs follow-up after merge

## Stage 7: Merge Back Into `onelink-main`

After review and validation:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink checkout onelink-main
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink pull --ff-only origin onelink-main
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink merge --no-ff sync/chatwoot-v4.12.1
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink push origin onelink-main
```

## Stage 8: Update Active Feature Branches

Only after `onelink-main` contains the sync:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink checkout feature/whatsapp-web-dashboard-suite
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink merge onelink-main
```

Or, if your team prefers a clean linear branch and the branch is not shared in a way that makes rebase dangerous:

```bash
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink checkout feature/whatsapp-web-dashboard-suite
git -C /Users/akhanbakhitov/Documents/zeroprompt/onelink rebase onelink-main
```

For this repo, merging `onelink-main` into feature branches is the lower-risk choice unless there is a strong reason to rewrite history.

## Recommended File Review Order For This Fork

Use this order during the actual sync session:

1. `Gemfile.lock`
2. `package.json`
3. `pnpm-lock.yaml`
4. `config/routes.rb`
5. `config/features.yml`
6. inbox and mailer files
7. core shared dashboard settings files
8. contact, company, conversation, message models/controllers
9. Captain/AI overlapping files
10. fork-only scheduling, MacroCRM, Medelement, WhatsApp Web
11. specs and swagger
12. final schema and runtime verification

## Explicit Conflict Policy

Use this decision rule when in doubt:

- if it is a security fix, dependency fix, or shared platform bugfix from upstream, keep upstream
- if it is Onelink-specific product capability, preserve it
- if a local customization exists only because the old upstream lacked something now present in `v4.12.1`, remove the local customization
- if a local customization and upstream both change the same flow, rebuild the local customization on top of the upstream file rather than restoring the old file wholesale

## Minimum Deliverables For The Sync PR

The sync branch should not be merged until it has:

- merged `v4.12.1`
- resolved conflicts cleanly
- updated lockfiles and runtime files consistently
- passed at least narrow backend verification
- passed dashboard smoke checks
- documented any intentional divergence kept from Onelink

## What To Do After The Base Sync

After `onelink-main` is updated:

1. refresh `feature/whatsapp-web-dashboard-suite`
2. refresh any other active long-lived branches
3. fix branch-specific conflicts separately
4. re-run branch-specific verification for scheduling, WhatsApp Web, MacroCRM, and Medelement

## Recommended Working Rule For The Team

From this point forward:

- do upstream intake only through `sync/chatwoot-vX.Y.Z`
- keep feature work off `onelink-main`
- avoid deep core patches when an extension point or isolated overlay will work
- sync upstream more frequently so the fork does not accumulate another `4.11.1 -> 4.12.1` size gap
