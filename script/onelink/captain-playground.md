# Captain profile and Playground contract

The profile and Playground use the same installed model parameter catalog. Model,
temperature and reasoning controls are in the settings gear. An absent or unknown
capability hides the control and omits the parameter from the model request.
Clearing or changing a model also removes settings that its catalog does not
confirm. The provider default is a valid choice. OpenRouter's explicit
`reasoning.supported_efforts: null` convention is used only for an installed
OpenRouter entry; an absent key or another provider does not expose every effort.

## Session and permissions

There is one workspace. Its caller, patients, deals, appointments and other
fixtures always belong to its JSON snapshot. Redis expires the session after
24 hours. Reset starts a new namespace with both permissions OFF. No Contact,
ContactInbox, Conversation, Message, appointment or provider command is created
when the workspace opens or its synthetic scenario changes.

Every synthetic ID is a negative handle bound to the server session. Positive
native IDs and synthetic local IDs are separate namespaces. Foreign-session and
unknown handles fail before a real record lookup. Turning real-data permissions
ON never promotes synthetic records. A synthetic document artifact is usable
only in that session and is never a production signed attachment.

* **Read real data** is OFF by default. It enables native account-scoped reads
  with the current operator's record permissions. Field definitions, model
  metadata and tool schemas can load with this switch OFF; customer values and
  real resource schedules cannot.
* **Change real data** is visible only when reading is ON and is OFF by default.
  Each real mutation requires its own preview and explicit confirmation. The
  preview binds account, operator, profile, session, generation, tool, exact
  target snapshot and arguments. A selected tool removed from the profile,
  changed target, changed arguments, expired preview or revoked permission
  invalidates confirmation. The exact target is checked again under record locks.
* Turning reading OFF also turns changing OFF and revokes pending previews.
  Turning changing OFF or resetting revokes approvals already captured by queued
  work. The provider send gate repeats inside its identity/source write fence.
* An unresolved OFF request blocks sending and confirmation in the browser until
  revocation is acknowledged. Old turn/confirmation responses cannot restore
  revoked switches or previews.

The caller has no implicit native conversation. Selecting a real appointment
patient requires the existing verified clinical identity resolver, exact IIN and
structured clinical names, rather than the chat label or a phone match. Real
appointment creation cannot create an unrecorded patient from the scenario.

External message, notification, confirmation delivery, retry and touch delivery
stay disabled. Synthetic versions update the transcript/snapshot only. A legacy
Live token cannot authorize a new provider send or a queued outbound message.
An already started, genuinely confirmed native provider command keeps its
readback/reconciliation path and cannot repeat its write.

## Synthetic tool support

Tools retain the production schema. The runtime relaxes only ID constraints for
the current server session, then decodes and validates membership before dispatch.
The selected profile and feature restrictions still apply. The registry exposes
`playground_support` as `synthetic`, `blocked_external_service` or
`blocked_no_adapter`; unsupported execution returns an explicit failure.

| Tool family | Snapshot adapter and shared native behavior |
| --- | --- |
| Contact get/search/update; contact notes and merge | Current-caller scope, native contact normalization/format validators, managed-field stripping, custom-attribute mutation helper, payload helpers and native merge identity guard. |
| Company get/search/create/update | JSON companies, caller-company association, native Company validators and CRM payload helpers. |
| Deals, pipelines, stages and deal timeline | Contact-scoped snapshots, explicit deal targets, native stage-entry movement/reason/required-field policies, field catalog and native timeline ordering/cursor. |
| Tasks and task timeline | JSON statuses/types/outcomes/staff/teams, native task normalizers and validators, native task payload and timeline ordering/cursor. Current-task operations use the scenario's explicit selection. |
| Contact/deal/task/appointment custom fields | Actual workspace definitions without customer values; shared FieldCatalog and CustomAttributes mutation/required-field helpers. |
| Resource/service catalogs, schedules, availability and slots | Editable JSON resource rules, breaks, holidays, workday overrides, time off, appointments and service links. Shared AvailabilityService, ResourceScheduleService, ResourceAvailabilityQueryService and AvailableSlotSearchService. |
| Appointment create/get/search/update/cancel/list | JSON patients and grants, native schemas, exact clinical-identity rules and shared availability; full compact scheduling payloads retain IDs, status and interval through ToolWrapper. |
| Conversation get/search/priority/labels/resolve/assignment/handoff | Current synthetic conversation, JSON labels/staff/teams and native assignment/status-reason validation. |
| Message send/edit/retry, notifications, response cancellation | Native content/channel/recipient validation and reply-window policy on unsaved projections; JSON transcript/notification/cancellation state only. No message builder, delivery job or transport. |
| Channel templates; touch create/cancel/delete/bulk cancel | Native ChannelTemplateCatalog, TouchOperations input compiler, Reminder schedule/fingerprint/payload and BulkCancelService eligibility; JSON touches and plan enrollments only. |
| Confirmation request/get/resolve | Exact JSON subjects and idempotency state; no native request or external delivery. |
| Documentation, FAQ, documents, articles and canned responses | Explicit JSON fixtures and production formatters; lexical fallback retrieval only. No embeddings, translation, live content lookup or answer cache. |
| `web_search`, `web_scrape_url`, `search_linear_issues`, `translate_message` | Explicitly blocked external service, including when real-data switches are ON. |
| Custom HTTP, MCP and skill scripts | Explicitly blocked at the wrapper and shared transport entry points. Their opaque operations cannot bypass action confirmation. |

The scenario editor supports multiple patients, deals and appointments, plus
advanced fixtures for companies, knowledge, tasks, touches, templates, staff,
teams and events. It uses one current synthetic conversation/channel. Alternative
channel/thread references unavailable in that snapshot fail explicitly. Catalog
edits refer to existing scenario resource/service/pipeline/stage IDs. Knowledge
fixtures exercise native lexical fallback and serialization; remote semantic
retrieval is not simulated.

`get_appointment_provider_status` is absent from the customer profile, its
Playground contracts and customer receipt hints. Internal Copilot lookup by
`provider_command_id`, provider receipt data and background reconciliation remain.

## Verification

The focused wrapper specs cover negative IDs and real-ID collisions, foreign
sessions, read/write defaults, exact approvals, revocation, profile tool changes,
native clinical identities, synthetic create/get lifecycles, full scheduling
payloads, field metadata, no business database writes and no external transports.
Adapter regressions exercise native hours/breaks/holidays/override/time-off errors,
template windows, recipient ambiguity, touch schedule/lifecycle, message editing,
task payloads and stage movement restrictions. Native provider regressions cover
unsent legacy refusal, already started read-only reconciliation and revocation
inside the write fence. Browser tests cover delayed responses, failed OFF
acknowledgement, model controls and pending-provider receipts.

Ruby verification must run against the agreed isolated database/Redis environment
with provider/network stubs. Adding these specs does not mean the newest combined
Ruby tree has passed until that run completes.
