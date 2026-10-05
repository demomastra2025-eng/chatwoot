# Scheduling Finance Removal — Stage 1 Report

## Repository and scope

- Repository: C:\Users\khamz\Documents\Codex\onelink-remove-finance-stage1-20261006
- Branch: codex/remove-scheduling-finance-stage1
- Base: rc/e-stage2 at 48990f08fdf86f61199dbf681df80255fab28321
- Package: 2 of 2 independent packages; includes the backend/API/Swagger work and the frontend commits cherry-picked onto this branch.
- Work stayed in this branch. No push, pull request, merge, PROD/DEV/SSH, credentials, or database access was performed.

## Changes

### Removed public finance surfaces

The following files and classes were deleted:

| File | Removed class or purpose |
| --- | --- |
| app/controllers/api/v1/accounts/scheduling/appointment_payments_controller.rb | Api::V1::Accounts::Scheduling::AppointmentPaymentsController |
| app/controllers/api/v1/accounts/scheduling/payments_controller.rb | Api::V1::Accounts::Scheduling::PaymentsController |
| app/controllers/api/v1/accounts/scheduling/expenses_controller.rb | Api::V1::Accounts::Scheduling::ExpensesController |
| enterprise/app/services/captain/tools/copilot/add_appointment_payment_service.rb | Captain::Tools::Copilot::AddAppointmentPaymentService |
| spec/requests/api/v1/accounts/scheduling/finance_spec.rb | Finance-only scheduling request specs |

The following route actions were removed beneath the account scheduling API prefix:

- POST /appointments/:appointment_id/payments and DELETE /appointments/:id/payments
- GET /payments
- GET /expenses, POST /expenses/pay_all, and POST /expenses/:id/pay

Appointment create/update no longer accepts payment_status, prepaid, settlement, or compensation inputs. Appointment and calendar filters no longer accept payment_status. Resource/service writes no longer accept compensation values. Appointment responses never expose payment_status. Public finance search inputs and values were removed from Captain appointment context, tool schemas, prompts, webhook payloads, and the manager-effectiveness report.

Scheduling pages, stores, cards, calendar forms, and pricing forms no longer show compensation or prepayment/payment controls. Service price and service_amount editing/display and normal appointment status CRUD remain. The deal-effectiveness payment/trade-in cards, columns, and CSV values were removed.

Automation compatibility is explicit: new rules cannot select payment_status conditions or cancel_appointment_payment. A previously saved payment_status condition or cancel_appointment_payment action is still hydrated; the old action runs as a no-op. The UI retains payment_status labels only for those legacy rows. The RU finance translations were removed; EN/KK strings were not changed.

### Seven-day API compatibility window

Scheduling::FinanceApiCompatibility reads SCHEDULING_FINANCE_API_COMPATIBILITY_STARTED_AT on each active? call; it does not start from branch date, boot time, or first request. The parser accepts an ISO8601 timestamp ending in Z or +00:00 only. For seven days from that anchor, payloads contain neutral legacy values with the existing types:

| Payload | Legacy keys while active |
| --- | --- |
| Appointment | compensation_type_snapshot=null; compensation_value_snapshot=0; compensation_percent_snapshot=0; prepaid_amount=0; prepaid_payment_method=null; settlement_amount=0; settlement_payment_method=null; payments=[]; expense=null |
| Resource and service price | compensation_type=null; compensation_value=0; compensation_percent=0 |
| Calendar | payments=[]; expenses=[] |

At anchor + 604800 seconds (including the exact boundary), these keys are omitted. service_amount, base price, and service prices remain. An absent or invalid setting keeps neutral fields indefinitely; an invalid value logs an actionable warning once per changed invalid setting without printing its value. The example in .env.example is commented out and is not active configuration.

### Kept closure and data boundaries

- db/schema.rb, db/migrate/**, and config/brakeman.ignore are unchanged. No database deletion or migration is claimed.
- Payment and Expense model stubs and their associations remain. The existing CRM field names remain reserved.
- payment_status remains internal for local cancellation restoration, including AppointmentImporterService#local_cancellation_payment_attributes. It is omitted from public appointment payloads, Swagger, and Captain context.
- FinanceSyncService remains as the small Stage 3 expense closure. sync! delegates to sync_expense_only!, which reconciles only the expense. Payment-journal math and Appointment#manual_payments_total are removed.
- A marked local-cancellation reopen in shared Scheduling::Appointments::UpsertService restores an unpaid expense only when the prior record was cancelled and marked and the saved record is non-cancelled with payment_status=paid. The general appointment create/update path does not reconcile finance.
- The MedElement importer/catalog/conflict/provider integration files and guards/reconciler/streams were not changed. The Stage 3 provider-boundary spec's prepare_paid_appointment! helper alone now seeds the equivalent adjustment payment explicitly (amount, payment kind, payment method, and actor); the existing flow assertions are unchanged.
- The account feature-flag spec now uses registered crm_deals for overflow storage. The unrelated migration spec uses retired_scheduling_feature only as an arbitrary raw fixture token; the migration itself is unchanged.
- Saved Reminder bodies can still contain finance field references. Those references now render blank after finance fields were removed from the appointment field context. The database was not read, so affected-record counts are unknown.

## Decisions and follow-up questions

- At the future integration deployment, set SCHEDULING_FINANCE_API_COMPATIBILITY_STARTED_AT to that deployment's UTC ISO8601 timestamp, for example 2030-01-15T12:00:00Z. The actual deployment date is unknown and remains an integration task. If the value is absent or invalid, neutral fields remain indefinitely; the integration owner must verify the configured value.
- Legacy automation conditions remain executable and the old payment action is a no-op. Whether to migrate or retire saved conditions/actions requires a separate compatibility decision.
- Existing Reminder text that references removed finance fields renders blank. Decide whether any additional handling of saved Reminder bodies is needed; no database inventory or mutation was attempted.
- The Stage 3 expense closure and MedElement compensation catalog/importer paths remain intentionally deferred. Their later removal requires a separate Stage 3 change and regression review.
- This work does not claim database columns/data, stub models/associations, reserved CRM keys, or Stage 3 finance flows have been removed.

## Validation

### Backend, Swagger, and boundary checks

- Passed: git diff --check from the specified base to the integrated branch.
- Passed: Prism syntax-only parser, 53 changed Ruby files and 0 parser errors.
- Passed: portable Swagger semantic check, 271 expanded YAML documents; swagger.json and all four tag-group JSON artifacts matched their source exactly. The helper reports rails_rake_executed=false.
- Passed: protected path diff is empty for db/schema.rb, db/migrate/**, and config/brakeman.ignore.
- Passed: rg found no references to manual_payments_total, upsert_payment_by_kind, or validate_totals! in app, enterprise, or spec.
- Ruby runtime availability check: ruby and bundle are unavailable. RSpec, RuboCop, Brakeman, Zeitwerk, Rails/Rake Swagger generation, and OpenAPI/Rails specs were not run. The Rails Swagger rake task was not represented as run. Bundle lock was not applicable because Gemfile was not changed.
- No database, migration, host integration, PROD, or DEV checks were run.

Exact backend commands:

    git -c safe.directory='C:/Users/khamz/Documents/Codex/onelink-remove-finance-stage1-20261006' diff --check 48990f08fdf86f61199dbf681df80255fab28321..HEAD
    node C:/Users/khamz/Documents/Codex/onelink-cleanup-tooling-20261006/check-ruby-syntax.mjs C:/Users/khamz/Documents/Codex/onelink-remove-finance-stage1-20261006 48990f08fdf86f61199dbf681df80255fab28321
    node C:/Users/khamz/Documents/Codex/onelink-cleanup-tooling-20261006/check-swagger-build.mjs C:/Users/khamz/Documents/Codex/onelink-remove-finance-stage1-20261006
    git -c safe.directory='C:/Users/khamz/Documents/Codex/onelink-remove-finance-stage1-20261006' diff --name-status 48990f08fdf86f61199dbf681df80255fab28321..HEAD -- db/schema.rb db/migrate config/brakeman.ignore
    rg -n 'manual_payments_total|upsert_payment_by_kind|validate_totals!' app enterprise spec

### Frontend validation

All commands below used the project's local Node dependencies. ESLint commands exited 0 with no errors. The full ESLint invocation used --quiet, which suppresses warnings.

Full changed-file ESLint command:

    node ./node_modules/eslint/bin/eslint.js --quiet app/javascript/dashboard/components-next/Scheduling/SchedulingAppointmentCard.vue app/javascript/dashboard/components-next/Scheduling/SchedulingVueCalCalendar.spec.js app/javascript/dashboard/components-next/Scheduling/SchedulingVueCalCalendar.vue app/javascript/dashboard/composables/spec/useEditableAutomation.spec.js app/javascript/dashboard/featureFlags.js app/javascript/dashboard/helper/automationHelper.js app/javascript/dashboard/helper/specs/automationHelper.spec.js app/javascript/dashboard/stores/scheduling/shared.spec.js app/javascript/dashboard/routes/dashboard/scheduling/constants.js app/javascript/dashboard/routes/dashboard/scheduling/pages/SchedulingCalendarPage.vue app/javascript/dashboard/routes/dashboard/scheduling/pages/SchedulingResourcesPage.vue app/javascript/dashboard/routes/dashboard/scheduling/pages/SchedulingServicesPage.vue app/javascript/dashboard/routes/dashboard/scheduling/servicePricing.js app/javascript/dashboard/routes/dashboard/scheduling/servicePricing.spec.js app/javascript/dashboard/routes/dashboard/settings/automation/AutomationRuleForm.vue app/javascript/dashboard/routes/dashboard/settings/automation/constants.js app/javascript/dashboard/routes/dashboard/settings/reports/DealReports.vue app/javascript/dashboard/stores/scheduling/appointmentForm.js app/javascript/dashboard/stores/scheduling/appointmentForm.spec.js app/javascript/dashboard/stores/scheduling/calendar.js app/javascript/dashboard/stores/scheduling/calendar.spec.js app/javascript/dashboard/stores/scheduling/shared.js app/javascript/dashboard/stores/scheduling/shared.spec.js

After the final backend cleanup, this changed-file ESLint check also passed:

    node ./node_modules/eslint/bin/eslint.js --quiet app/javascript/dashboard/stores/scheduling/shared.js app/javascript/dashboard/stores/scheduling/shared.spec.js

Vitest commands used PowerShell environment variables TEST=true and TZ=UTC and worker flags --maxWorkers=2 --minWorkers=1:

    $env:TEST='true'; $env:TZ='UTC'; node ./node_modules/vitest/vitest.mjs run app/javascript/dashboard/composables/spec/useEditableAutomation.spec.js app/javascript/dashboard/helper/specs/automationHelper.spec.js app/javascript/dashboard/routes/dashboard/settings/reports/DealReports.spec.js app/javascript/dashboard/routes/dashboard/settings/automation/Index.spec.js app/javascript/dashboard/routes/dashboard/settings/automation/automation.routes.spec.js --maxWorkers=2 --minWorkers=1
    Result: 5 files, 69 tests passed. This reran the previously failing automation suites and included report/automation route coverage.

    $env:TEST='true'; $env:TZ='UTC'; node ./node_modules/vitest/vitest.mjs run app/javascript/dashboard/helper/specs/automationHelper.spec.js app/javascript/dashboard/i18n/specs/translationKeys.spec.js app/javascript/dashboard/stores/scheduling/shared.spec.js --maxWorkers=2 --minWorkers=1
    Result at that point: 3 files, 78 tests passed (57 helper, 5 translation guard, 16 shared). These counts overlap other batches and are not additive.

    $env:TEST='true'; $env:TZ='UTC'; node ./node_modules/vitest/vitest.mjs run app/javascript/dashboard/stores/scheduling/shared.spec.js app/javascript/dashboard/i18n/specs/translationKeys.spec.js --maxWorkers=2 --minWorkers=1
    Final backend-delta rerun: 2 files, 18 tests passed (13 shared and 5 translation guard).

    $env:TEST='true'; $env:TZ='UTC'; node ./node_modules/vitest/vitest.mjs run app/javascript/dashboard/i18n/specs/translationKeys.spec.js --maxWorkers=2 --minWorkers=1
    Translation guard: 1 file, 5 tests passed.

The first broad frontend invocation accidentally omitted the Vitest run subcommand and entered watch mode: 9 files completed with 119 passing tests and 2 failing cases. The failures were stale test fixtures/expectations in automation-row hydration and metadata. Both were fixed and the affected suites passed in the explicit 5-file rerun above; the watch process was stopped. These initial results are recorded as intermediate only and are not added to later batch totals.

The frontend owner also ran a non-quiet ESLint pass earlier that reported 435 pre-existing localization warnings and three Prettier errors; the three formatting errors were fixed. The final quiet ESLint commands above have no errors. Vitest batches overlap and should not be summed as unique tests.
