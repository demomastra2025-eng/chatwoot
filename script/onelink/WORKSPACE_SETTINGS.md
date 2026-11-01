# Workspace settings consolidation

The workspace account owns the clinic schedule, greeting, out of office reply, automatic conversation assignment, assignment policy, and customer facing AI reply timing. Inbox rows keep their historical columns for rollback, but runtime decisions use the account settings.

## Common replies

`workspace_greeting` stores `enabled`, `message`, and `excluded_inbox_ids`. New text channels inherit the greeting unless excluded; email and voice do not send text greetings. `workspace_out_of_office` stores `enabled` and `message` and uses the company schedule, breaks, days off, and timezone. Its editor is beside the company hours. A company without a saved schedule is always open, so its closure reply does not run. New companies start with both replies disabled.

Existing companies require an explicit cutover. Deploying the new runtime before preparing their settings would suppress legacy messages. The migration service never sends messages or overwrites retired inbox columns.

1. Prepare the new reviewed release directory and its dependencies without switching the running application. Run all preparation commands below **from that directory**, using the target environment; the old application and API keep running until step 4. Inspect `bundle exec rake workspace_replies:preflight` in read-only mode. It prints only account IDs, digests, and conflicting setting names, then fails while any account is unprepared. Keep message texts out of logs and shared artifacts.
2. Freeze old settings writers during the maintenance window. For an unambiguous account, run `ACCOUNT_ID=<id> EXPECTED_DIGEST=<digest> bundle exec rake workspace_replies:migrate` from the prepared release directory. Account and inbox locks plus the inspected digest reject concurrent changes. This is a database write and requires the environment's release authorization.
3. Divergent legacy texts require an explicit choice of the company's message and greeting channel exclusions. Create a private operator-only JSON file with exactly the pending keys (`workspace_greeting` and/or `workspace_out_of_office`), using the shapes described above. Run `ACCOUNT_ID=<id> EXPECTED_DIGEST=<digest> CONFIG_PATH=<private-file> bundle exec rake workspace_replies:migrate` from the same prepared release directory. The same migration service checks the digest, keys, schema, and account-scoped exclusions atomically. Do not use the old Account API: it does not support the new fields. Do not pick the first inbox or silently enable all old channels. Remove the private file after use and repeat preflight. Paused greeting drafts are preserved when they agree; different paused drafts also require a choice.
4. Preflight must succeed with an empty pending list before switching all application writers and readers to the new runtime and UI together. Keep old writers frozen until the switch completes. Verify business hours, greeting exclusions, disabled replies, and new channel inheritance using synthetic contacts on DEV before owner review.
5. For rollback, return application and UI to the previous reviewed release together. Legacy inbox values remain intact; common settings remain available for another cutover. Changes made only to common settings after cutover are not copied back to legacy inboxes automatically: inspect and obtain an explicit choice before reverting customer facing behavior.

Inbox API writes to retired greeting, closure reply, hours, or timezone fields return `422 company_managed_settings` before updating other fields. Existing inbox response keys project the common settings. Support tools read the same policy; the working hours tool updates the company schedule.

## Clinic schedule

`accounts.settings` stores `workspace_timezone`, seven `workspace_working_hours` entries, optional breaks, and optional days off. An account without a saved seven day schedule is always open for open now checks. Specialist resources created after this change inherit the workspace schedule; existing specialists keep their personal schedules. A specialist can switch to a personal schedule. Account schedule updates refresh inheriting specialists.

Migration `20260901131000` copies the first enabled inbox's complete weekly schedule and timezone into an account that lacks a workspace schedule. It leaves accounts with no enabled inbox schedule unscheduled and sets all inboxes to inherit. Migration `20260903091307` adds the specialist inheritance flag with a false database default so existing personal schedules stay intact. Both migrations preserve old rows and are safe to rerun.

## Staff and assignment

Every account user is a member of every account inbox, including voice inboxes. The SIP phone and extension assignment still belongs to a specific user. Migration `20261014100000` inserts missing inbox memberships with conflict handling, selects the workspace auto assignment value by inbox majority (ties are on), and copies an account's linked assignment policy. Existing per inbox values and policy links remain stored. New users and inboxes fill memberships automatically.

Legacy inbox membership removal requests retain workspace members. The Copilot removal tool reports only IDs actually removed, so its `removed_user_ids` array is empty when workspace membership keeps those users.

The channel collaborators and working hours pages are removed. Virtual PBX setup still has a SIP profile step where an operator is assigned a phone and extension; it no longer changes inbox membership. Twilio and text channels finish without a staff selection step. The public and dashboard inbox payloads project the workspace schedule and assignment switch. Response time reporting uses the workspace weekly hours; its historical metric still omits break and day off intervals.

## Text AI routing

The workspace has one active external main agent. Each text channel has one AI switch, while the account has an emergency switch and a reply time mode. A text channel with AI enabled enters through the main agent and can reach every other active external agent. Voice routing remains on its existing path. Without a configured workspace schedule, the only effective text reply mode is `always`.

Migration `20261014101000` counts distinct conversations handled by linked entry agents using message sender identifiers only. For an account with multiple linked agents it selects the one with the highest count, breaking ties by age and ID. With no linked AI channels, it chooses the oldest active external agent. It keeps old channel and agent selection rows, points existing text links at the selected main agent, and turns on those existing links. Text channels without a link remain off. A marker in account settings prevents reruns from undoing later operator changes. New text channels start enabled when a main agent is available.

Playground starts from the workspace main agent when one exists. A chosen text channel exposes active colleagues; without a channel the main agent works alone. When no main agent exists, Playground retains the selected agent as a fallback.

The `docs/` submodule was unavailable in this local clone, so this internal note lives beside the OneLink delivery documentation. Client facing docs still need synchronization in the docs repository before release.
