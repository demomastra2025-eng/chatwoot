# cx-agentscope: patient-facing Captain tool scope

## Changes and decisions

- The external agent adapter uses `SCOPE_AGENT`; staff Copilot uses `SCOPE_ASSISTANT`. The current patient is the contact stored on the current account conversation. The agent ignores contact IDs in model arguments and the context's separate contact field when choosing the patient.
- Own appointments have `contact_id` equal to that contact or `conversation_id` equal to the current conversation. Own deals have a `crm_deal_contacts` row for that contact. `patient_contact_id` is deliberately excluded. Explicit own appointment IDs can be used across conversations, including when the patient has several bookings. Staff Copilot's conversation-only appointment mutation rule remains unchanged.
- Reads and searches for contacts, conversations, appointments, provider command receipts, and deals now use patient relations. Patient deal output omits other linked contacts, company details, next action, and foreign origin context. CRM pipeline and stage catalogs no longer expose account-wide deal counts to the external agent.
- A denied record ID or spoofed contact filter yields the same `record_not_available` result with `retryable: false`, regardless of whether the requested record belongs to someone else or does not exist. Scoped `exists?` checks precede detail reads and writes.
- Built-in tools without a safe patient ownership rule are hidden from the agent catalog and rejected if invoked directly. Staff Copilot retains them. The full list is in the table below.
- Denied attempts publish `llm.captain.tool.denied`, which the existing recorder persists in `llm_events`. The event carries tool name, current account/conversation/contact IDs, ID kind, and `outcome: denied`; it never includes a supplied ID, name, phone, or message text. Existing tool execution audit receives empty arguments for these denials. Recording failure does not turn a denial into access.
- No schema change, migration, new dependency, prompt edit, editor change, or production data operation was made.

## Built-in agent tool audit

“Shared” means a clinic knowledge, configuration, or scheduling resource catalog rather than a patient record. “Unbound” means unavailable in `SCOPE_AGENT` and still available in staff scope. This table covers every registry tool previously available in agent scope that searches records, accepts a record ID, uses a record from runtime context, or writes a record; non-record controls are included for completeness.

| Tool | Reads or writes | Before | After in `SCOPE_AGENT` |
| --- | --- | --- | --- |
| `search_documentation` | Search knowledge documents | Assistant knowledge | Shared assistant knowledge; kept |
| `list_captain_documents` | List document metadata | Assistant-visible documents | Shared assistant-visible documents; kept |
| `faq_lookup` | Search FAQ | Assistant knowledge | Shared assistant knowledge; kept |
| `web_search` | Search public web | Public web | Same; kept |
| `web_scrape_url` | Read public URL | Public web | Same; kept |
| `add_contact_note` | Write contact note | Separate contact ID in runtime state | Persisted conversation contact in current account |
| `add_private_note` | Write conversation note | Current account conversation | Same conversation, with verified patient contact |
| `add_label_to_conversation` | Read shared label, write conversation labels | Current account conversation | Same conversation, with verified patient contact |
| `update_priority` | Write conversation priority | Current account conversation | Same conversation, with verified patient contact |
| `resolve_conversation` | Write conversation status | Current account conversation | Same conversation, with verified patient contact |
| `handoff` | Hand off current conversation | Current conversation | Same; kept |
| `cancel_response` | Stop response | Current run | Same; kept |
| `send_notification` | Read recipient and target conversation, write notification | Account recipient and optional account conversation | Unbound |
| `search_conversations` | Search conversation summaries | Account search with optional contact ID | Forced to current contact; spoofed contact ID denied |
| `get_contact` | Read contact profile | Any account contact ID | Current contact only |
| `search_contacts` | Search contact profiles | Account-wide name/email/phone search | At most current contact, including text queries |
| `update_contact` | Write contact profile | Current conversation contact | Same, with verified patient contact |
| `get_company` | Read company | Any account company ID | Unbound; companies can be shared |
| `search_companies` | Search companies | Account-wide | Unbound |
| `create_company` | Write company and contact link | Current contact, new account company | Unbound |
| `update_company` | Write linked company | Company linked to current contact | Unbound; company can include other contacts |
| `get_deal` | Read deal | Any account deal ID | Deal linked to current contact; other-contact metadata omitted |
| `search_deals` | Search deals | Account-wide for title query or absent contact filter | Forced current contact for every query and filter |
| `list_deal_pipelines` | Read pipeline/stage catalog | Shared catalog plus account-wide deal counts | Shared catalog without account-wide deal counts |
| `list_deal_stages` | Read stages, optional deal | Shared catalog, optional account deal ID | Shared catalog; optional deal must be own; no account-wide counts |
| `list_deal_custom_fields` | Read deal field definitions | Shared clinic configuration | Same; kept |
| `get_deal_timeline` | Read deal events | Any account deal ID | Unbound; timeline may include other contacts |
| `create_deal` | Write deal | Current conversation contact | Same; verified contact; output omits other-contact metadata |
| `update_deal` | Write deal | Explicit account deal ID or context deal | Explicit or context deal must be linked to current contact |
| `transition_deal_stage` | Write deal stage | Context deal | Context deal must be linked to current contact |
| `get_task` | Read task | Any account task ID | Unbound; tasks are staff records |
| `search_tasks` | Search tasks | Account-wide | Unbound |
| `list_task_custom_fields` | Read task field definitions | Shared configuration | Unbound with task tools |
| `get_task_timeline` | Read task events | Any account task ID | Unbound |
| `create_task` | Write task | Optional account deal/conversation IDs | Unbound |
| `update_task` | Write task | Explicit account task ID or context task | Unbound |
| `change_task_status` | Write task status | Context task | Unbound |
| `list_channel_templates` | List messaging templates | Shared clinic configuration | Same; kept |
| `create_touch` | Write scheduled reminder | Context conversation/deal/task/appointment | Unbound; reminder ownership is not independently safe |
| `cancel_touch` | Cancel reminder by ID | Any account reminder ID | Unbound |
| `delete_touch` | Delete reminder by ID | Any account reminder ID | Unbound |
| `cancel_touches` | Bulk cancel context reminders | Context record and optional plan | Unbound |
| `request_confirmation` | Write confirmation request | Current conversation; context subject unchecked | Verified patient contact and own appointment/deal subject; task subject denied |
| `get_confirmation_request` | Read confirmation request | Current conversation, subject unchecked | Current conversation and own subject checked |
| `resolve_confirmation` | Write confirmation resolution | Any account confirmation request ID | Current conversation and own subject checked |
| `get_appointment` | Read appointment | Any account appointment ID | Own contact or current conversation only |
| `search_appointments` | Search appointments | Account-wide without contact filter | Forced to own contact or current conversation for all filters and text queries |
| `list_appointment_custom_fields` | Read appointment field definitions | Shared clinic configuration | Same; kept |
| `list_scheduling_resources` | List specialists/resources | Shared clinic resources | Same; kept |
| `search_scheduling_resources` | Search specialists/resources | Shared clinic resources | Same; kept |
| `get_scheduling_resource_schedule` | Read specialist working schedule | Shared clinic resource ID | Same; kept |
| `get_scheduling_resource_availability` | Read resource availability | Shared clinic resource ID | Same; kept |
| `search_scheduling_services` | Search service catalog | Shared clinic services | Same; kept |
| `search_available_slots` | Search availability | Shared clinic resources/services | Same; kept |
| `create_appointment` | Write appointment | Current conversation contact | Verified patient contact; IDs in model arguments cannot set contact |
| `update_appointment` | Write appointment | Current conversation appointment only | Explicit own-contact or current-conversation appointment; neutral denial otherwise |
| `cancel_appointment` | Cancel appointment | Current conversation appointment only | Explicit own-contact or current-conversation appointment; neutral denial otherwise |
| `get_appointment_provider_status` | Read provider command receipt | Any account command ID | Command must link to own appointment |
| `get_article` | Read help article | Shared help center | Same; kept |
| `search_articles` | Search help articles | Shared help center | Same; kept |
| `search_linear_issues` | Search integrated issue records | Account integration | Unbound |
| `send_message_to_conversation` | Write message/attachment | Account conversation ID | Unbound |
| `assign_conversation` | Write assignment | Account conversation ID | Unbound |
| `retry_failed_message` | Retry message | Account message ID | Unbound |
| `edit_message` | Write message | Account message ID | Unbound |
| `translate_message` | Read message | Account message ID | Unbound |
| `search_canned_responses` | Search internal snippets | Account-wide | Unbound |
| `merge_contacts` | Merge two account contacts | Any account contact IDs | Unbound; no identity-linking flow added |
| `remove_label_from_conversation` | Write conversation labels | Account conversation ID | Unbound |

## Verification

| Check | Result |
| --- | --- |
| `git diff --check` | Passed before commits. |
| `ruby -c` for every changed Ruby file | Passed. |
| `bundle exec rubocop --force-exclusion --fail-level warning` on all 30 changed Ruby files | Exit 0. It reported 45 convention offenses below the requested warning threshold; no warning or higher offense. |
| Database-backed RSpec, including new patient-scope specs | **Not run**: this machine has no Postgres/Redis. The release engineer must run them. |
| ESLint/Vitest | **Not run**: no JavaScript/Vue files changed, and this machine has no `node_modules` per the task environment. |

## Kept and open questions

- Staff Copilot service methods, account-wide staff searches, and staff UI/API routes retain their existing behavior. Shared clinic scheduling resources, service and slot catalogs, public articles, and assistant-visible knowledge remain available to the external agent.
- `patient_contact_id` was not used for ownership. Should a representative ever be allowed to see a booking whose `patient_contact_id` is someone else, and what verification is required?
- A deal linked to several contacts qualifies as own under the selected rule. The agent response removes other contact metadata, but the deal's own title, description, and custom fields may themselves contain information about multiple people. Should such deals be unavailable until the product has a per-person data rule?
- Custom tools, MCP tools, and skill scripts are configured dynamically and can call external systems. This task left them configured as they were; their data sources need an owner-approved patient-scope contract before this guarantee can cover them. No contact merge or one-time-code flow was added.
- `docs/` is an uninitialized git submodule in this clone (`git submodule status` reports `-f9d69d3... docs`), and there is no remote. Internal/public docs could not be updated here. This report records the runtime change for the documentation update in the release integration environment.
