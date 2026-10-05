# Scheduling Finance Removal — Stage 1 Report

## Changes

- Removed Stage 1 scheduling payment and expense API routes/controllers, finance request handling, and the finance-only request/controller tests.
- Removed finance inputs and tools from Captain scheduling context, appointment search, prompts, tool schemas, and the CRM manager-effectiveness report. Removed the obsolete trade-in report source as well.
- Removed normal scheduling create/update finance calculations and finance-only model validations while retaining appointment status handling needed by local cancellation and MedElement.
- Kept service_amount, service prices, service price snapshots, and service price API behavior.
- Removed the scheduling_finance backend feature flag. Updated the account overflow test to use the registered crm_deals feature; changed the unrelated migration spec's raw fixture token to retired_scheduling_feature so it continues testing arbitrary stored overflow data without relying on an unregistered feature.
- Updated the Swagger source and five generated JSON artifacts. The portable builder expanded 271 YAML documents and found structural equality between source and generated files.
- Removed finance endpoint references from the Onelink integrator docs.
- Appointment payloads never expose payment_status. For seven days from an explicitly configured integration timestamp, old API keys have neutral values with their prior types: integer amounts/compensation values are 0, nullable strings and the single expense object are null, and payment/expense collections are empty arrays. These keys are omitted at and after the cutoff. Service price and amount fields remain available.
- Removed finance field expectations from the Reminder rendering spec and added assertions that old finance field references render blank. Other field and price assertions remain.

## Kept for compatibility and Stage 3

- db/schema.rb, migrations, and config/brakeman.ignore are unchanged. Payment and Expense model stubs and their associations remain. Existing CRM finance field names remain reserved.
- payment_status remains an internal cancellation marker, including AppointmentImporterService#local_cancellation_payment_attributes. It is absent from the public appointment API, Swagger, and Captain context.
- Existing automation rules can still evaluate their saved payment_status conditions. The cancel_appointment_payment action remains registered for old rules and is a tested no-op; the new UI choice is handled in the separate frontend work.
- FinanceSyncService remains as a minimal expense-only closure for unchanged Stage 3 MedElement callers: sync! delegates to sync_expense_only!, which reconciles only the expense. A narrow shared scheduling reopen branch invokes it only when the saved appointment was previously a marked local cancellation and is now non-cancelled with payment_status paid. Regular creates/updates do not run finance reconciliation. The old payment journal math and Appointment#manual_payments_total were removed.
- MedElement catalog/importer/conflict/provider integration files were left unchanged. The local cancellation marker importer attribute remains. The staff-reopen expense repair is in shared Scheduling::Appointments::UpsertService; it does not alter the MedElement guards or reconciler.
- The spec/db/migrate/remove_smm_postiz_data_spec change only replaces an unregistered fixture feature name; the migration itself is unchanged. In the Stage 3 provider boundary spec, the existing paid-appointment helper now seeds the equivalent adjustment payment explicitly so unchanged flow assertions still exercise expense creation without restoring removed payment synchronization.

## Integration gate and open questions

- At the future integration deployment, set SCHEDULING_FINANCE_API_COMPATIBILITY_STARTED_AT to that deployment's UTC ISO8601 timestamp, for example 2030-01-15T12:00:00Z. The value must include Z or a UTC offset. The seven-day window starts from that deployment timestamp, not from this branch, application boot, or the first request. At started_at + 604800 seconds the compatibility keys are omitted.
- If the setting is absent or invalid, neutral legacy fields remain enabled indefinitely until a valid setting is provided. Invalid settings emit a warning that does not include the configured value. The exact deployment date is unknown and remains an integration task; no production setting was changed here.
- Saved Reminder bodies containing finance field:// references now render those references as blank. The database was not inspected, so the number of affected saved bodies is unknown. Confirm whether a separate read-only legacy rendering path is desired before changing this behavior.
- Existing saved automation conditions on payment_status remain executable while the new choice is hidden. Whether to migrate or retire old conditions needs a separate compatibility decision.
- The minimal Stage 3 dependency closure remains intentionally deferred. Its removal requires a separate Stage 3 change and regression review.

## Checks

- git diff --check: passed after all current backend changes.
- Ruby syntax parser (@ruby/prism@1.9.0): 53 changed Ruby files parsed, 0 syntax errors.
- Portable Swagger semantic check: passed for all five generated artifacts; 271 expanded documents; rails_rake_executed: false.
- Protected-path diff (db/schema.rb, db/migrate/**, config/brakeman.ignore): empty. app/javascript/** is outside this backend worktree's changes.
- Added regression examples for the Stage 3 cancellation expense cleanup path, including mismatched legacy totals and preserving payment IDs and audit attributes. RSpec could not run because Ruby/Rails are unavailable in this environment; Rails/Rake Swagger generation was not run. Vitest was not run in this worktree while the frontend owner was running the shared Vite cache checks.


