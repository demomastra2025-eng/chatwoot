# One Link API Surfaces

Use this reference first when the main question is "which API should I use?"

## Default Rule

Start with the Application API unless there is a clear reason to use another surface.

## Application API

Best for:

- workspace operations
- contact and conversation sync
- inbox and team workflows
- CRM and scheduling integrations
- automation-connected operational tools

Typical path family:

- `/api/v1/accounts/{account_id}/...`

Authentication:

- header: `api_access_token`
- usually a user-scoped token
- some operations may also support an agent bot token

## Client API

Best for:

- custom website chat clients
- embedded messaging experiences
- mobile or portal messaging tied to One Link conversations

Typical path family:

- `/public/api/v1/inboxes/{inbox_identifier}/contacts/...`

Observed client path shapes in the current API reference include:

- `/public/api/v1/inboxes/{inbox_identifier}/contacts`
- `/public/api/v1/inboxes/{inbox_identifier}/contacts/{contact_identifier}`
- `/public/api/v1/inboxes/{inbox_identifier}/contacts/{contact_identifier}/conversations`
- `/public/api/v1/inboxes/{inbox_identifier}/contacts/{contact_identifier}/conversations/{conversation_id}/messages`

Authentication and identity model:

- client-side flow anchored to an inbox identifier
- contact-scoped identity in the client conversation flow
- do not treat a workspace user token as a client-side credential

## Platform API

Best for:

- managed account setup
- provisioning users or accounts
- operational or partner-level admin flows

Typical path family:

- `/platform/api/v1/...`

Observed platform path shapes in the current API reference include:

- `/platform/api/v1/accounts`
- `/platform/api/v1/accounts/{account_id}/account_users`
- `/platform/api/v1/agent_bots`
- `/platform/api/v1/users`

Authentication:

- header: `api_access_token`
- platform-scoped token

## Selection Heuristics

- If the integration acts like a workspace operator, choose Application API.
- If the integration renders a customer-facing chat experience, choose Client API.
- If the integration provisions or administrates workspaces across accounts, choose Platform API.

## Security Reminder

- Keep Application and Platform tokens server-side.
- Do not place operator or platform tokens in browser code.
