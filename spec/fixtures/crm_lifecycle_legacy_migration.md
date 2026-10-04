# CRM lifecycle migration compatibility fixture

Run these only in the isolated CRM migration test database, after loading the target base schema and before applying the new CRM lifecycle migration:

1. `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f spec/fixtures/crm_lifecycle_legacy_seed.sql`
2. Run the CRM lifecycle migration through the normal Rails migration command.
3. `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f spec/fixtures/crm_lifecycle_legacy_verify.sql`

The seed creates existing tasks for accounts with missing, JSON-null, blank, whitespace-only, invalid, and valid reporting timezones. Valid values cover IANA names and a Rails display label. The verification checks timezone backfill and preservation of task status, outcome, date-only fields, and historical deadlines, plus explicit catalog mapping without inferred cancellation, duplicate-stage compatibility, an estimated current-stage visit without invented older visits, default-off stage restrictions, and inserts through old task/event writer column sets.

Do not run this fixture against customer, DEV, or PROD data.
