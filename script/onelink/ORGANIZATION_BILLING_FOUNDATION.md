# Organization billing foundation

This is a source/schema foundation, not a runtime billing switch. Account plans,
invoices, roles, branch linking and all quota readers retain their existing paths.
No bootstrap or resolver is installed. The seat unit awaits owner decision 15.

## Schema and legacy data

`20261102093000` manages only `billing_accounts`, `billing_subscriptions` and
`billing_account_workspaces`. When all three are absent it creates them without
restoring the retired plan/price/membership/allocation catalogue. When all exist
it checks the exact columns, nullability, all significant defaults and the absence
of unexpected default expressions, real valid primary keys on id, owned ID
sequences, validated checks, live/ready/valid unique indexes and foreign keys before
changing anything. Partial or incompatible
structures stop with an explicit error; the migration runs transactionally.

Existing records become `foundation_state=legacy_pending`; their owner, dates,
snapshots, status and catalogue references remain unchanged. They are read-only
through these models and excluded from `ready` scopes. No owner/date/paid term is
inferred. New records default to `ready` and cannot be created as legacy pending
through the models. A future separately reviewed adoption procedure must resolve
legacy conflicts explicitly; it is absent here.

Ready payers require exactly one Organization or standalone Account owner.
Ownership keys are immutable in the models and unique even after closure, so a
closed payer's history cannot silently be replaced by a second owner contract.
Ready workspace intervals are `[starts_at,detached_at)`; the PostgreSQL GiST
exclusion constraint prevents overlap across payers, including concurrent inserts.
The existing unique active workspace constraint remains. The Account foreign key
restricts deletion, preserving financial history. `btree_gist` is required in the
application database and is enabled by the migration; no server extension is
installed outside the isolated test database during development.

## Snapshots

`Billing::PlanSnapshot.compile` takes a tariff from `Accounts::Plans`, explicit
manual overrides and explicit resolved defaults for limits left null by the
catalogue. These are internal migration/service inputs, not new client settings.
The compiler neither reads nor writes an Account, and cannot invent missing
effective values. The caller must obtain defaults/manual values using the
existing LimitSettings/ApplyPlan contract after checking all involved workspaces.
Missing defaults and unresolved custom enterprise monetary terms fail explicitly.
The compiler does not choose how seats are counted or calculate a seat charge.

Snapshots retain catalogue/schema versions, tariff/modules/features, all compiled
limits with their sources, currency and tariff price fields. New subscriptions
must exactly match a fresh compilation from the sole Accounts::Plans, including
names, sources, limit values, prices and catalogue version. Unknown or contradictory
new contracts return a validation error. Persisted subscriptions and preflight use
stable historical structure/source-value validation: custom and plan values are
integers, an archived unlimited value is positive, only a resolved default may be
nil. This path never consults today's YAML names, monetary values or unlimited
sentinel; changed/removed catalogue entries do not rewrite saved terms. No new
catalogue or runtime setting chooses this distinction. New subscriptions do not
use legacy plan/price IDs. Existing catalogue foreign keys remain provenance and
become nullable; no fake legacy plan is inserted for a new snapshot contract.

Model `attr_readonly` raises on subsequent assignment/update of owner and snapshot
fields; normal ORM updates cannot silently change a past contract. Direct SQL and
`update_all` are privileged bypasses, not an exposed service contract. No trigger
that would disappear from `schema.rb` on schema loading is introduced. Database
checks independently enforce owner XOR/FKs, known interval shape and the basic
snapshot envelope; full typed snapshot validation is in `PlanSnapshot`.

## Preflight and rollback

Run `bundle exec rake billing:foundation:preflight` from the reviewed source.
It opens its own PostgreSQL READ ONLY transaction. Output contains only presence
flags, billing entity IDs and diagnostic codes; no customer names, requisites,
Account/user IDs, patient data or tokens. Missing/unmanaged structures and legacy
mapping produce a nonzero result without repair. This readiness is limited to the
foundation; it does not authorize activation of billing or shared quota readers.

Rollback application code while retaining this additive schema. `down` explicitly
raises `IrreversibleMigration` before mutation. It never deletes occupied tables,
catalogue references or financial history, and cannot restore the old destructive
workspace Account cascade. Any eventual reverse migration requires a reviewed,
data-specific plan.

## Acceptance

Use only the isolated `chatwoot_logic_billing_foundation_test` database on 55996
and Redis database 7 on 56996. Tests cover a fresh schema, a separately preserved
abadea legacy structure with synthetic occupied rows, rejected structural drift,
non-destructive rollback, SQL owner/time/FK guards, actual two-connection interval
conflict, snapshot immutability and PostgreSQL refusal of accidental diagnostic
writes. No live migration, legacy adoption, external financial call or activation
is part of these checks.
