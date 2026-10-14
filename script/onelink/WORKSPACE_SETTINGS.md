# Workspace settings consolidation

The workspace account now owns the clinic schedule, automatic conversation assignment, assignment policy, and customer facing AI reply timing. Inbox rows keep their historical columns for compatibility, but runtime decisions use the account settings. The inbox out of office message remains a channel specific message.

## Clinic schedule

`accounts.settings` stores `workspace_timezone`, seven `workspace_working_hours` entries, optional breaks, and optional days off. An account without a saved seven day schedule is always open for open now checks. Specialist resources created after this change inherit the workspace schedule; existing specialists keep their personal schedules. A specialist can switch to a personal schedule. Account schedule updates refresh inheriting specialists.

Migration `20260901131000` copies the first enabled inbox's complete weekly schedule and timezone into an account that lacks a workspace schedule. It leaves accounts with no enabled inbox schedule unscheduled and sets all inboxes to inherit. Migration `20260903091307` adds the specialist inheritance flag with a false database default so existing personal schedules stay intact. Both migrations preserve old rows and are safe to rerun.

## Staff and assignment

Every account user is a member of every account inbox, including voice inboxes. The SIP phone and extension assignment still belongs to a specific user. Migration `20261014100000` inserts missing inbox memberships with conflict handling, selects the workspace auto assignment value by inbox majority (ties are on), and copies an account's linked assignment policy. Existing per inbox values and policy links remain stored. New users and inboxes fill memberships automatically.

The channel collaborators and working hours pages are removed. Virtual PBX setup still has a SIP profile step where an operator is assigned a phone and extension; it no longer changes inbox membership. Twilio and text channels finish without a staff selection step. The public and dashboard inbox payloads project the workspace schedule and assignment switch. Response time reporting uses the workspace weekly hours; its historical metric still omits break and day off intervals.

## Text AI routing

The workspace has one active external main agent. Each text channel has one AI switch, while the account has an emergency switch and a reply time mode. A text channel with AI enabled enters through the main agent and can reach every other active external agent. Voice routing remains on its existing path. Without a configured workspace schedule, the only effective text reply mode is `always`.

Migration `20261014101000` counts distinct conversations handled by linked entry agents using message sender identifiers only. For an account with multiple linked agents it selects the one with the highest count, breaking ties by age and ID. With no linked AI channels, it chooses the oldest active external agent. It keeps old channel and agent selection rows, points existing text links at the selected main agent, and turns on those existing links. Text channels without a link remain off. A marker in account settings prevents reruns from undoing later operator changes. New text channels start enabled when a main agent is available.

Playground starts from the workspace main agent when one exists. A chosen text channel exposes active colleagues; without a channel the main agent works alone. When no main agent exists, Playground retains the selected agent as a fallback.

The `docs/` submodule was unavailable in this local clone, so this internal note lives beside the OneLink delivery documentation. Client facing docs still need synchronization in the docs repository before release.
