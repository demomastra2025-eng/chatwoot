# One Link Resource Groups

Use this reference when the main question is "where in the API does this business object live?"

## Main Account-Scoped Resource Families

| Resource group | Typical path family | What it covers |
| --- | --- | --- |
| Contacts | `/api/v1/accounts/{account_id}/contacts` | Customer identity, search, filtering, import/export |
| Conversations | `/api/v1/accounts/{account_id}/conversations` | Messaging threads, assignment, labels, status, attributes |
| Messages | `/api/v1/accounts/{account_id}/conversations/{conversation_id}/messages` | Inbound and outbound message operations |
| Companies | `/api/v1/accounts/{account_id}/companies` | Organization-level records |
| Inboxes | `/api/v1/accounts/{account_id}/inboxes` | Channel queues and inbox configuration |
| Automation rules | `/api/v1/accounts/{account_id}/automation_rules` | Event-driven workspace workflows |
| Macros | `/api/v1/accounts/{account_id}/macros` | Reusable operator-triggered actions |
| Integrations | workspace settings and integration resources under the account | Installed app lifecycle and connected systems |
| Portals and articles | `/api/v1/accounts/{account_id}/portals/...` | Knowledge base content and settings |

## Scheduling Families Confirmed In The Current Reference

Observed path families include:

- `/api/v1/accounts/{account_id}/scheduling/resources`
- `/api/v1/accounts/{account_id}/scheduling/services`
- `/api/v1/accounts/{account_id}/scheduling/appointments`
- `/api/v1/accounts/{account_id}/scheduling/appointments/{appointment_id}/payments`

Use scheduling APIs for:

- resources and calendars
- services and booking configuration
- appointments
- payment and finance-related scheduling records

## CRM And Business Workflow Areas

Public docs describe CRM as covering:

- pipelines
- stages
- task statuses
- field definitions
- deals
- tasks
- comments and timelines under deal and task sub-resources

Important note:

- if you need exact CRM request or response contracts, verify them against the current API reference or the UI network flow
- do not assume the path family until the current contract confirms it

## Captain And AI Areas

Public docs describe Captain as covering:

- assistants
- inbox bindings
- scenarios
- documents
- assistant responses
- copilot threads and messages
- custom tools

If you are integrating with Captain:

- separate AI-callable tools from general integration lifecycle behavior
- check whether the task is a Captain custom tool or a broader connected app

## Client API Resource Families

For customer-facing messaging clients, the main public path family is:

- `/public/api/v1/inboxes/{inbox_identifier}/contacts/...`

Typical client tasks include:

- creating or updating a contact
- opening a conversation
- sending a message
- toggling typing state
- updating last seen

## Practical Rule

Map the integration by business object first, then confirm the exact path in the current reference before writing code.
