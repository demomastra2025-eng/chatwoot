# PII feedback counters

Read-only aggregate operator report (no new UI/settings):

```sh
bundle exec rake 'pii:feedback[123]'
bundle exec rake 'pii:feedback[global]'
```

The explicit `global` scope is required to aggregate tenants. Invalid/missing account IDs raise instead of falling back to global. Numeric account scope can also be read via `Llm::PiiFeedbackMetrics.summary(account_id: 123)`. No text, name/digest labels, answers, tokens or keys appear in the report.

## Units and interpretation

Counters start with the first successful v3 Redis write (`observed_since` UTC). They are cumulative until those Redis keys are removed. Existing v2 process counters are not imported: their missing cross-process data cannot be recovered.

- `text_checks`: nonblank, non-protocol `record_mask_pass!` calls while shadow is ON, **not unique messages or patients**. The same text can be checked many times. `checks_with_masked_pii` counts checks containing a placeholder; name/phone/IIN counts count unique placeholders **within each check**, including the native ten-character IIN token.
- `eligible_checks`: calls with candidate words and an account. Direct enqueue calls are eligible admission requests with zero `text_checks`. `skipped_no_candidates`, `skipped_policy`, `skipped_duplicate`, `skipped_rate` explain admission decisions. Async policy failures also increment `skipped_policy`; the skip counters are events, not a disjoint partition of text checks.
- `admission_grants`: atomic Redis reservations, including subsequent `enqueue_failed` reservations. Failure releases the original minute's latch/rate capacity. Grant counters remain cumulative; no negative compensation hides failures.
- `audit_attempts`: worker/diagnostic attempts that acquired the existing in-flight lease and recorded their start. Retries count additional attempts. `audit_failed`, `audit_unavailable` and `skipped_policy` do not mean clean. Errors/unavailable results return `missed: nil`.
- `audit_completed`: completed, live-lease-owned audits with a Redis enqueue reservation. The completion and outcome counters are one Lua transaction and are deduplicated for the existing one-hour audit TTL. `diagnostic_audits_completed` are direct audits without an enqueue reservation and are excluded from coverage. Unknown/low-confidence answers can complete transport but increment `decider_unknown_predictions`, never clean.
- `completed_per_eligible_check`, `admitted_per_eligible_check` and `completed_per_admission_grant` describe observed audit coverage and queue progress. They are **not detection accuracy**. Repeated checks/dedup/rate/policy limits and pending jobs reduce coverage. Counters do not imply all messages were audited.
- `decider_suspected_misses` counts high-confidence allowed overall flags, not true false negatives. `decider_clean_predictions` remains an unverified prediction. `new_quarantined_names` counts new tenant/category HMAC members atomically with SADD, including discoveries preceding a failed/retried completion. Contradictory/unknown answers never activate names.
- `verified_name_promotions` counts newly activated tenant/category members; `verified_quarantine_promotions` is the subset previously quarantined. Both commit atomically with learned SADD and tenant version. Repeated native confirmations do not inflate promotions. There is no global learning from a decider response.
- `verified_boundary_unmasked_names` is a bounded observation: a provider-verified name word also appeared unmasked among this request scope's candidate words. It **does not prove patient attribution** (the same word may name a doctor). The request stores at most 256 HMACs and discards them with the existing pseudonymizer scope; this is not a queue.

There are no human/gold rejection labels yet. `confirmed_false_negatives`, `rejected_predictions`, `precision`, and `recall` are `null`, not zero or 99%. A provider snapshot confirms recorded identity, not the semantic role of every occurrence or clinical truth.

## Learning boundary

`PatientBookingContext` calls the verification hook only after native same-account, valid-IIN, single-record, name-match and birth-date checks on an **existing** card. The hook additionally requires a provider code, valid `medelement_iin`, and provider `medelement_first_name`/`medelement_last_name` snapshot; it learns only provider snapshot name fields. `CARD_KEY` alone is insufficient: local AI-authored cards can have that flag and must not bootstrap learning on a repeat call. The new-card path and self-declared public identifiers never supply proof. Explicit low-level verified APIs are internal; they default to unverified and do not create proof from AI arguments.

## Operational limits

With `PII_SHADOW_AUDIT_ENABLED` not exactly `true`, the hook performs no new Redis/DB I/O, stores no evidence and buffers no pending metrics. OFF periods are unobserved. With ON each text check makes one bounded atomic Redis admission/counter EVAL, including checks without candidates; no extra queue/pipeline/daemon exists. Existing per-account 30/min admission, dedup, retry, native account key, provider-only/ZDR/budget routing and in-flight leases remain in use. Accountless checks are counted in an isolated bucket and cannot enqueue or audit with a global API key.

Redis read failure returns `status: unavailable`, `counters: null`. Empty keys return `status: not_observed`, no observation start and null coverage. Successful read does not prove no historical outage: counters cover acknowledged writes, not OFF periods or lost storage. All native Lua mutations validate key types and bounded integer counters before any write (Lua runtime errors do not roll back earlier commands). Redis admission errors fail closed; no unbounded RAM retry queue is created. This is observability, not a durable financial/audit ledger. No production flag is changed by this task.

## Isolated validation

Relevant specs:

```sh
bundle exec rspec spec/lib/llm/pii_session_pseudonymizer_spec.rb \
  spec/enterprise/lib/captain/tools/agent/patient_booking_context_spec.rb \
  spec/lib/llm/pii_feedback_metrics_spec.rb
PII_FEEDBACK_REDIS_URL=redis://127.0.0.1:56996/14 \
  bundle exec rspec spec/lib/llm/pii_shadow_auditor_native_spec.rb
```

Native proofs replace only the test process's Redis pool with a random namespace, verify process aggregation, a shared 30/48 rate cap, duplicate/lease completion, corrupt type/integer rejection and tenant learning, then delete only that namespace's keys. No `FLUSHDB`, API traffic or dependencies are needed. Run only after the test-lane owner approves the prepared DB/Redis lane.
