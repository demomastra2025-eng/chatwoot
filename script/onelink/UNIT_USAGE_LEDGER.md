# Unit usage ledger: source-only

The entry points are `Billing::UsageLedger.preview` and `.reconcile!`. No runtime
producer, callback, cron, invoice, payment, renderer, API or feature flag invokes
them. This does not activate shared billing or choose the pending seat rule.

## Explicit inputs

Both methods take numeric `account_id`, canonical `event_ids`, complete event
`provenance`, `expected_version`, and `contact_id` for AI scopes. Provenance maps
each event ID to exactly `workspace_id`, `period_id` and `subscription_id`.
`merge_from` maps old financial projection IDs to their expected versions.
`baseline: :empty` is an internal prerequisite for a first projection, not a
client assertion that bypasses source verification: the service checks the full
SQL event set and refuses unimported legacy markers/seeds/windows.

AI events remain account+contact scoped, sharing the existing 24h/20 timeline.
The optional fourth timeline tuple member is a numeric source ID. Three-member
callers retain their exact result shape. Financial windows retain their first
event ID and its original period/subscription/workspace. Source tuples are
immutable once captured even when Contact merge changes the clinical contact ID.

Call scopes contain one already-classified canonical AiUsageEvent from the
existing call-seconds bucket; no second CallUsageEvent/classifier is introduced.
Period seconds accumulate across branches; `call_minutes` rounds the combined
seconds once, with integer arithmetic. No monetary calculation is performed.

Missing source/clinical identity/provenance/legacy baseline/historical terms
returns `needs_review` without postings. A caller subset, deleted Contact or
missing source never turns a prior allocation into zero. No six-month Account
cache, current organization, current YAML or present-day subscription supplies
missing financial history. Extra input fields are rejected without echoing them.

## Period proof

Periods must be explicitly created and supplied; reconciliation never creates
one. A period captures immutable plan/price snapshots from a ready subscription
and observed renewal-cycle evidence covering the month-start anchor. For Nov1,
Oct15–Nov15 is valid evidence: renewal need not cover the entire AI calendar
month. The subscription must already exist at that anchor. The copied anchor
evidence is immutable; subsequent reads never reconstruct it from today's cycle.

An existing proven period survives an ordinary renewal. Each NEW event also needs
a freshly locked, entitling subscription whose actual current cycle contains that
event and whose creation predates it. A month anchor never supplies entitlement.
The service alone captures an exact-event typed witness in projection.sources,
binding the canonical event/account, core provenance, observed status and cycle.
It cannot be supplied by the caller or transferred to another event. Confirmed
witnesses remain byte-identical across replay, merge, late insertion, renewal and
later cancellation. Snapshots and owner must still match. Existing sources without
that witness are refused without writes: source02293 was never activated and is
not an adopted financial baseline. A historical event outside the currently known
cycle without its own prior witness requires review; no lifecycle is inferred.
Different term snapshots encountered for a new event within the
month return `needs_review`; no proration, second quota or invented monetary
transition is selected. Ambiguous historical coverage remains refused. The
captured cycle is anchor evidence, not a new definition of contract duration.

## Persistence and replay

Three additive tables contain periods, current financial projections and signed
append-only revisions. Projections have no Contact FK/cascade and retain only
numeric identities, source times, units and provenance. Account/financial FKs
restrict deletion. Mutable AiDialogState is not the financial baseline.

Reconciliation compares the previous target plus all explicit merge sources
against the new shared-timeline projection. It appends signed deltas by period
and increments projection versions atomically. A late first event may move one
window B→A while Account total delta remains zero. An A→B→A sequence remains
legal; fingerprints have no global uniqueness constraint. Exact replay creates
no revision. A new same-window reply updates source provenance/version without
creating a zero-valued financial revision. Stale different input returns conflict.

Explicit merge retires the old financial projections into the target and writes
the net correction. Their original sources and allocations remain available for
audit. Source disappearance and clinical deletion are not merge instructions.

## Lock and integration boundary

The source-only writer owns this order: existing account identity advisory lock
(AI) → existing Contacts by ID → Account `FOR NO KEY UPDATE` → all predetermined
payers by ID → subscription rows by ID (fresh cycle/status reload) → workspace/
source rows → financial projections by ID → periods by
ID. All branch writers for one payer serialize before updating period revisions.
No provider IO runs under these transactions. Preview calculates without writes;
reconcile reloads under locks and verifies the expected projection version.

An outer transaction may include canonical source/state/cache writes and ledger
postings, provided the caller acquires the complete earlier lock set first. The
targeted rollback test demonstrates this; it does not install a runtime hook.
The ledger uses a savepoint inside an existing transaction: an expected refusal
also rolls back partial financial writes when the outer caller handles the result.
Before integration, every producer/merge/link/term writer must adopt the common
order, and future Invoice/Profile paths must not reacquire Account/Contact after
payer/period locks. Those paths, durable invoice continuation/reservations,
financial cutover, monetary corrections and seat enforcement are not implemented
here. No new global queue or automatic backfill is installed.
In particular, future subscription lifecycle writers must take payer before term
rows, including inserts: these source-only locks do not install that runtime protocol.

The additive migration refuses pre-existing ledger tables rather than silently
adopting them. `down` explicitly refuses destructive rollback; keep the financial
schema/history and roll back application source. Development uses only
`chatwoot_logic_org_usage_ledger_test` on 55996 and Redis7 on 56996, guarded before
create/DDL; old foundation, review and live databases are excluded.
