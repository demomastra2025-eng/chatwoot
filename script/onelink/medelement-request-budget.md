# MedElement request budget

Every MedElement HTTP attempt, including retries and the read-only sample capture, is counted in Redis by UTC hour, account, hook, caller lane, operation, and status. The counters expire after eight days. HTTP 429 entries retain the first request number in that hour, the last safe rate-limit headers and a classified body hint. Patient data and credentials are never stored in these counters.

Run `bundle exec rake medelement:requests:report HOURS=24` to inspect the volume. The report includes durations, 429 counts, pauses, and the request number where the first 429 occurred. Compare several days and clinics before changing a budget; a 429 after few requests can reflect a provider limit outside the per-second rule.

The integration hook settings accept `request_budget_per_minute` (default 30), `live_reserve_per_minute` (default 10), and `rate_alert_threshold_per_hour` (default 3). The budget is shared by all operations for the same credential. The live reserve means background calls can use at most 20 of the default 30 tokens each minute. AI booking, command, patient lookup, and UI availability calls use the live lane. Schedule windows covering today or tomorrow use `sync_near`; later windows use `sync_far`; other jobs use `other_jobs`. One quarter of the background share (five default tokens) is kept for `sync_near`; `sync_far` and other jobs share the rest. All background lanes pause together after a provider 429. `Retry-After` controls the pause when present; otherwise it grows exponentially from five seconds. A live request can still use its reserve during that pause.

Tune one clinic at a time: find the lowest `first_429_at_count`, reduce the per-minute budget below the observed onset, and keep enough live reserve for expected interactive traffic. Use the hourly caller mix and request count to check whether a lower budget postpones background sync. Do not infer a provider-wide quota from a single clinic or hour.

The schedule horizon remains 90 days. Today and tomorrow refresh hourly; days 2–14 refresh every 12 hours; days 15–89 refresh every 48 hours. A changed reception in the existing delta stream marks its specialist and date for an earlier timetable read. Confirmed schedule windows remain available after provider errors. The super-admin dashboard flags clinics that cross their hourly 429 threshold; the MedElement integration diagnostics show the same hour's counters and threshold.

The docs submodule is not initialized in this local release clone, so this operator note lives alongside the release scripts.
