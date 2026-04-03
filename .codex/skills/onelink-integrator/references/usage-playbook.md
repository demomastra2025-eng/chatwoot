# One Link Integrator Usage Playbook

Use this reference when you need a practical prompt shape or answer structure.

## Good Prompt Templates

### 1. Choose The Right Surface

Use when the user knows the business goal but not the API family.

Example:

`Use $onelink-integrator to choose the correct One Link API surface for a mobile app that lets customers continue support conversations from our portal.`

### 2. Plan A Workspace Sync

Use when the user needs a system-to-system integration.

Example:

`Use $onelink-integrator to design a webhook-driven sync between One Link and our ERP for contacts, companies, and appointment completion.`

### 3. Draft Initial Requests

Use when the user needs first-pass request examples.

Example:

`Use $onelink-integrator to draft cURL examples for creating a contact and opening a conversation through the Application API.`

### 4. Debug Auth Or Scope

Use when the user is mixing up user, client, or platform credentials.

Example:

`Use $onelink-integrator to explain why our browser app should not use a workspace api_access_token and what the safer client-side approach is.`

### 5. Confirm A Path Family

Use when the user knows the business object but not the exact route family.

Example:

`Use $onelink-integrator to identify the likely One Link API path family for appointment payments and tell me what to confirm in the current OpenAPI reference.`

## Recommended Answer Shape

For most integrator tasks, answer in this order:

1. recommended API surface
2. authentication model
3. likely path family
4. webhook need or event model
5. implementation sequence
6. contract checks still required

## When To Ask For More Input

Ask for clarification only when one of these is unknown and changes the answer materially:

- whether the integration is operator-side or customer-facing
- whether the integration needs write access
- whether the integration is workspace-scoped or platform-scoped
- whether the flow is synchronous or event-driven
