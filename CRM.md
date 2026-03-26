# Shared CRM Runtime for Onelink

## Status

- Document type: target implementation contract
- Scope: shared CRM runtime inside the Onelink monolith
- Design priority: native to current architecture, reliable under concurrency, extensible for future vertical modules
- Source of truth after implementation: code

## Purpose

Onelink should implement one shared CRM runtime, not a separate CRM product per vertical.

That runtime must:

- reuse existing `Contact`, `Conversation`, `Company`, `Team`, `User`, and account-scoped patterns
- add first-class CRM entities only where lifecycle is stable across multiple domains
- support both standalone user tasks and deal-linked tasks
- support account-defined CRM custom fields without weakening stable domain invariants
- stay additive to the current support-platform architecture

This document replaces a broad planning draft with a stricter implementation contract for the first native CRM build.

## Non-Goals

- do not turn `Conversation` into `Deal`
- do not redefine current `Contact` semantics or repurpose `crm_v2`
- do not introduce a second auth or permissions system
- do not overload current `Note` or `CustomAttributeDefinition` with CRM-specific behavior
- do not make migration of legacy external CRM integration code a phase-0 blocker
- do not build one generic polymorphic "business record" table for all CRM behavior
- do not expose public hard delete for operational CRM records in v1

## Native Fit Rules

The CRM runtime must feel like it belongs to the current codebase.

That means:

- account-scoped models and queries
- `Current.account` and `Current.account_user` remain the ambient request context
- backend authorization stays in Pundit with the existing `pundit_user` shape
- dashboard gating stays in `currentAccount.permissions`, `FEATURE_FLAGS`, and `route.meta.permissions`
- controllers follow the `scheduling` pattern for base controller, error rendering, payload rendering, and idempotency behavior
- services own writes and transitions; model callbacks must not orchestrate CRM workflows
- enterprise overlays remain overlays; core CRM code should live in `app/` unless the capability is already enterprise-only

## Existing Primitives That Remain Canonical

The CRM runtime must reuse current primitives instead of replacing them.

### `Contact`

- `Contact` remains the person-level record
- `contact_type` stays owned by contact lifecycle, not by deal lifecycle
- CRM may link to any account contact
- CRM v1 must not silently reinterpret `visitor`, `lead`, or `customer`
- won deals do not automatically convert a contact into `customer` in v1

If product later wants explicit conversion rules, add a dedicated service such as `Contacts::Lifecycle::PromoteToCustomerService`. Do not hide that behavior inside deal transitions.

### `Conversation`

- `Conversation` remains the communication and support aggregate
- a deal may reference one `originating_conversation_id`
- CRM timelines may surface filtered conversation history, but CRM does not own message storage
- CRM permissions do not replace conversation visibility rules

### `Company`

- `Company` remains the organization-level association
- `company_id` is valid and useful on deals from day one
- deal payloads and filters may expose company summary even if the separate companies UI is disabled
- `company_id` must not expand message visibility or bypass contact/conversation policies

### `Team`

- `Team` remains the routing and grouping primitive
- `team_id` is optional on deals and tasks
- team membership may influence defaults and reporting, but account membership is the hard invariant

### `CustomAttributeDefinition`

- it remains the custom-field system for `Contact` and `Conversation`
- CRM v1 must not extend it to `Deal` or `Task`
- existing widget and pre-chat side effects are not CRM concerns

## Namespace and Placement

### Runtime CRM

New first-party CRM runtime code should live under:

- `app/models/crm/*`
- `app/services/crm/*`
- `app/controllers/api/v1/accounts/crm/*`
- `app/policies/crm/*`
- `app/javascript/dashboard/routes/dashboard/crm/*`

### Legacy External CRM Integration Code

The codebase already has legacy external CRM integration classes under `Crm::*`.

That is not a blocker for v1.

Rules:

- first-party runtime CRM may still live under `Crm::*`
- legacy external adapter code may temporarily coexist under subnamespaces such as `Crm::Leadsquared`
- all new external provider adapters should go under `Integrations::Crm::*`
- migrating old external adapter code out of `Crm::*` is a follow-up cleanup, not a prerequisite for shipping the shared CRM runtime

## Feature Flags

Do not introduce a long-lived `crm_v3` flag.

Do not reuse or reinterpret existing flags:

- `crm`
- `crm_integration`
- `crm_v2`

Use additive capability flags appended to `config/features.yml`:

- `crm_deals`
- `crm_tasks`

Optional internal umbrella flag:

- `crm_runtime`

Rules:

- new flags are append-only
- existing feature bit positions must not be repurposed
- deals and tasks can roll out independently
- settings endpoints should require the capability they configure

Examples:

- pipelines and stages depend on `crm_deals`
- task statuses depend on `crm_tasks`
- field definitions for `deal` depend on `crm_deals`
- field definitions for `task` depend on `crm_tasks`

## Permissions and Access Model

### Source of Truth

Authorization must remain native to the current stack:

- backend: Pundit policies plus policy scopes
- frontend: `currentAccount.permissions` plus route meta permissions
- identity: `pundit_user = { user:, account:, account_user: }`

### New CRM Permissions

Extend custom-role permissions with:

- `crm_deal_view`
- `crm_deal_manage`
- `crm_task_view`
- `crm_task_manage`
- `crm_settings_view`
- `crm_settings_manage`

This requires updating both backend and frontend permission lists.

### Role Behavior

- `administrator` has full CRM access
- plain `agent` gets default operational access to deals and tasks when the respective feature is enabled
- agents with a custom role must receive explicit CRM permissions through `CustomRole.permissions`
- settings management must never be implied by operational deal/task access

Recommended route-meta pattern:

- deals screens: `['administrator', 'agent', 'crm_deal_view', 'crm_deal_manage']`
- task screens: `['administrator', 'agent', 'crm_task_view', 'crm_task_manage']`
- settings screens: `['administrator', 'crm_settings_view', 'crm_settings_manage']`

The backend remains the final authority.

### Access Scope Rules

All CRM access is account-scoped.

V1 record-visibility rules:

- if a user is allowed to view deals, they may view all deals in the current account
- if a user is allowed to view tasks, they may view all tasks in the current account
- `owner_id` and `team_id` are assignment and filtering attributes, not authorization boundaries in v1
- future owner- or team-restricted CRM visibility may be added later, but it must be introduced as an explicit new policy layer

Important separation:

- deal/task authorization is controlled by CRM policies
- conversation visibility inside CRM timeline is still controlled by conversation permissions
- linked contact and company summaries may be visible inside CRM payloads without granting standalone management access to those modules

### Permission Semantics

`crm_deal_view` allows:

- list deals
- show deal detail
- view deal kanban
- view deal timeline
- view linked contact and company summaries included in deal payloads

`crm_deal_manage` allows:

- create deal
- update deal
- transition deal stage
- archive and unarchive deal
- link and unlink contacts on a deal
- create, update, and delete deal comments

`crm_task_view` allows:

- list tasks
- show task detail
- view task calendar
- view task timeline
- view linked deal summary included in task payloads

`crm_task_manage` allows:

- create task
- update task
- change task status
- archive and unarchive task
- create, update, and delete task comments

`crm_settings_view` allows:

- list pipelines
- list stages
- list task statuses
- list CRM field definitions
- open CRM settings screens in read-only mode

`crm_settings_manage` allows:

- create and update pipelines
- create and update stages
- create and update task statuses
- create, update, deactivate, and delete CRM field definitions where allowed by policy

Manage permissions imply the corresponding view permissions in backend policy logic.

### Access Matrix

- `administrator`: full access to deals, tasks, timelines, comments, and CRM settings
- plain `agent`: operational access to deals and tasks, but no CRM settings management
- custom-role agent with only `crm_deal_view`: read-only access to deals
- custom-role agent with `crm_deal_manage`: full deal operations
- custom-role agent with only `crm_task_view`: read-only access to tasks
- custom-role agent with `crm_task_manage`: full task operations
- custom-role agent with only `crm_settings_view`: read-only CRM settings access
- custom-role agent with `crm_settings_manage`: full CRM settings management

### Operational Reads vs Settings Screens

Operational users still need read access to CRM configuration metadata required by forms and list rendering.

Rules:

- deal forms may receive active pipelines and stages as supporting metadata
- task forms may receive active task statuses as supporting metadata
- field catalog for `deal` or `task` may be exposed as part of operational create and edit flows
- this supporting metadata does not mean the user can open CRM settings or mutate configuration

This avoids a broken UX where agents can operate deals and tasks but cannot load the metadata required to render forms.

### Frontend Route and Policy Note

Custom-role agents do not inherit the plain `agent` shortcut in the same way as default account users.

Therefore:

- frontend routes must include explicit `crm_*` permissions, not rely only on `agent`
- backend policies must not rely on route-meta shortcuts
- request authorization must always be checked server-side

### Frontend Reference and Reuse Note

Frontend implementation should treat the existing scheduling pages as the main UI reference for CRM operational screens.

Primary reference surface:

- `SchedulingCalendarPage`
- `SchedulingToolbar`
- `SchedulingViewSwitcher`
- `SchedulingCalendarGrid`
- `SchedulingKanbanBoard`
- `SchedulingRecordTable`
- `SchedulingDrawer`
- scheduling filters and inline form-group patterns

Reason:

- scheduling already implements the closest native Onelink pattern for account-scoped operational work
- it already supports calendar, list, and kanban presentations behind one coherent page shell
- it already has toolbar, filters, drawer, status actions, empty state, and error state patterns that fit the dashboard better than inventing a second visual system for CRM

Recommended reuse:

- task calendar should reuse the scheduling calendar page composition and calendar visual language
- task list and deal list should reuse the existing table and list-page patterns where possible
- deal kanban and task kanban should reuse the scheduling kanban interaction model and page framing where possible
- CRM forms should reuse drawer-based create and edit flows, field groups, filters, and supporting metadata loading patterns established by scheduling
- conversation sidebar actions may deep-link into CRM create flows with route-query prefill instead of embedding a second create form inside inbox UI
- one-shot route prefill should be consumed by the CRM page, applied to the create drawer, and then cleared from the URL

Important limit:

- reuse the page shell, presentation patterns, and shared UI components
- do not copy scheduling domain-specific form fields, labels, or appointment-specific business logic into CRM
- if a scheduling component can be extracted into a truly generic dashboard component with low risk, prefer extraction over cloning
- if generalization would delay delivery or distort either domain, keep separate domain components behind the same visual language

### Identity Rules

The following fields always reference `User` ids, not `AccountUser` ids:

- `owner_id`
- `assignee_id`
- `creator_id`
- `actor_id`

Validation rule:

- referenced users must belong to the current account

### Contact and Company Read Semantics

CRM screens may expose minimal linked summaries without granting full management permissions on those entities.

Examples:

- a deal payload may include linked contact names and phone/email summary
- a deal payload may include company name and domain summary

That does not grant access to full contact-management or company-management screens.

### Conversation Visibility

CRM must never bypass conversation visibility.

If CRM surfaces related conversations or message excerpts, it must filter them through the existing conversation permission filter service before serialization.

## Core Domain Model

CRM v1 introduces separate business aggregates for deals and tasks.

### `Crm::Pipeline`

Core columns:

- `account_id`
- `name`
- `code`
- `position`
- `active`
- `default`
- timestamps

Rules:

- unique `code` per account
- exactly one default active pipeline per account
- pipelines are configuration entities, not operational records
- if a pipeline is already referenced by deals, deactivate instead of deleting

### `Crm::Stage`

Core columns:

- `account_id`
- `pipeline_id`
- `name`
- `code`
- `position`
- `outcome`
- `active`
- timestamps

`outcome` enum:

- `open`
- `won`
- `lost`

Rules:

- unique `code` within pipeline
- stage belongs to the same account as its pipeline
- moving a deal between stages is the only supported deal-state transition primitive in v1
- stage configuration should ensure at least one open stage and at least one terminal stage per pipeline

### `Crm::Deal`

Core columns:

- `account_id`
- `pipeline_id`
- `stage_id`
- `owner_id`
- `creator_id`
- `team_id`
- `company_id`
- `originating_conversation_id`
- `title`
- `description`
- `amount_minor`
- `currency`
- `expected_close_on`
- `closed_at`
- `win_probability`
- `external_ref`
- `idempotency_key`
- `lock_version`
- `custom_attributes`
- `archived_at`
- timestamps

Rules:

- `stage_id` must belong to `pipeline_id` and the same account
- `owner_id`, `creator_id`, and `team_id` are optional, but when present must belong to the same account
- `company_id` is optional
- `originating_conversation_id` is optional, but when present must belong to the same account
- at create time the deal must end up with at least one related party:
  - a linked contact
  - or `company_id`
  - or `originating_conversation_id`
- if `originating_conversation_id` is present and the conversation has a contact, the create service should auto-link that contact as primary unless the caller explicitly provides another primary contact
- `amount_minor` uses integer minor units
- `currency` is required when `amount_minor` is present
- `win_probability` is optional, integer `0..100`
- `closed_at` is managed by transition services, not raw params
- `archived_at` hides the record from default queries

### `Crm::DealContact`

Core columns:

- `account_id`
- `deal_id`
- `contact_id`
- `primary`
- timestamps

Rules:

- unique pair: `deal_id + contact_id`
- at most one primary contact per deal
- contact must belong to the same account
- this join table is the native way to support one deal with multiple people without collapsing the deal into contact-only storage

### `Crm::TaskStatus`

Core columns:

- `account_id`
- `name`
- `code`
- `position`
- `category`
- `active`
- `default`
- timestamps

`category` enum:

- `open`
- `done`

Rules:

- unique `code` per account
- exactly one default open status per account
- statuses are configuration entities
- if a status is already referenced by tasks, deactivate instead of deleting

### `Crm::Task`

Core columns:

- `account_id`
- `deal_id`
- `status_id`
- `assignee_id`
- `creator_id`
- `team_id`
- `originating_conversation_id`
- `title`
- `description`
- `priority`
- `start_at`
- `due_at`
- `completed_at`
- `external_ref`
- `idempotency_key`
- `lock_version`
- `custom_attributes`
- `archived_at`
- timestamps

`priority` enum:

- `low`
- `medium`
- `high`
- `urgent`

Rules:

- task may be standalone or linked to a deal
- `deal_id` is optional
- `status_id` must belong to the same account
- if `deal_id` is present, the deal must belong to the same account
- `assignee_id`, `creator_id`, and `team_id` are optional, but when present must belong to the same account
- `originating_conversation_id` is optional, but when present must belong to the same account
- `creator_id` should be written by user-facing create flows
- `completed_at` is managed by status transition services, not raw params
- `archived_at` hides the record from default queries
- when a task is created under a deal and `team_id` is omitted, the create service may default it from the deal
- when a task is created under a deal and `assignee_id` is omitted, the create service may default it from the deal owner
- when a task is created under a deal and `originating_conversation_id` is omitted, the create service may default it from the deal
- a standalone task may still reference `originating_conversation_id` when it was launched from inbox context

### `Crm::Comment`

Core columns:

- `account_id`
- `commentable_type`
- `commentable_id`
- `user_id`
- `body`
- `deleted_at`
- timestamps

Rules:

- supported commentable types in v1:
  - `Crm::Deal`
  - `Crm::Task`
- comments are for CRM discussion and notes on CRM entities
- current `Note` remains contact-only
- if compliance/history matters, prefer soft delete over hard delete

### `Crm::Event`

Core columns:

- `account_id`
- `eventable_type`
- `eventable_id`
- `actor_id`
- `event_type`
- `meta`
- `created_at`

Rules:

- supported eventable types in v1:
  - `Crm::Deal`
  - `Crm::Task`
- events back user-facing timelines
- `actor_id` may be null for system-generated events
- `meta` stores structured snapshots and transition details, not free-form blobs from AR serialization

### `Crm::FieldDefinition`

Core columns:

- `account_id`
- `entity_kind`
- `key`
- `label`
- `description`
- `field_type`
- `required`
- `active`
- `position`
- `default_value`
- `options`
- `rules`
- timestamps

`entity_kind` enum:

- `deal`
- `task`

Supported v1 field types:

- `text`
- `textarea`
- `number`
- `currency`
- `percent`
- `checkbox`
- `date`
- `datetime`
- `select`
- `multiselect`
- `url`

Rules:

- unique `key` per account and `entity_kind`
- custom-field keys must not conflict with built-in CRM system fields
- this model stores CRM custom fields only
- values live in `custom_attributes` on the owning record
- if a field already has stored values, prefer deactivation over destruction
- `rules` is the extension point for context-aware behavior

## Universal Field Catalog

CRM must support custom fields in a way that is systematic, native, and future-safe.

The correct model is not "everything is a column" and not "everything is an untyped JSON blob".

Use a merged field catalog:

- built-in CRM system fields are defined in code
- account-specific CRM custom fields are stored in `Crm::FieldDefinition`
- read and write APIs consume one unified field catalog per entity

Recommended service:

- `Crm::FieldCatalog`

Responsibilities:

- return built-in plus custom fields for `deal` or `task`
- mark which fields are system fields and which are custom fields
- expose filterability, searchability, editability, defaults, and context constraints
- validate key collisions between built-in and custom fields
- provide one contract to forms, filters, imports, payload builders, and validators

This mirrors the spirit of current contact/conversation custom attributes while avoiding leakage of their implementation constraints into CRM.

### Entity Coverage Policy

Not every entity should participate in the managed CRM field-definition system.

Use the following rule set.

Managed CRM custom fields in v1:

- `Crm::Deal`
- `Crm::Task`

Existing platform entities that may keep raw `custom_attributes`, but are outside the CRM field-definition system:

- `Scheduling::Appointment`
- `Scheduling::Service`
- `Scheduling::Resource`
- `Scheduling::Holiday`
- `Scheduling::TimeOff`
- `Scheduling::WorkdayOverride`

Configuration entities that should not get dynamic custom fields in v1:

- `Crm::Pipeline`
- `Crm::Stage`
- `Crm::TaskStatus`

Reason:

- `Deal` and `Task` are user-facing operational records with real need for tenant-specific forms, filters, exports, and workflow metadata
- scheduling entities already support lightweight JSON metadata and do not yet justify a second managed field-definition layer
- pipelines, stages, and statuses are workflow configuration records; if they need extra behavior such as `color`, `sla_days`, `system_code`, or UI hints, prefer explicit columns

### When a New Entity Deserves Managed Custom Fields

Add a new entity to the managed field-definition system only if at least two of the following are true:

- tenants need to capture extra fields in first-party forms
- those fields must round-trip through the API in a stable way
- those fields must be filterable or searchable in list views
- those fields matter for exports, imports, or reporting

If the need is only one or two internal knobs, do not add dynamic fields. Add normal columns instead.

### Future Platform-Level Generalization Rule

Do not build a global "fields for every entity in the platform" framework in v1.

If later the product truly needs one shared field-definition engine across CRM and scheduling, that extraction should happen only after at least two non-CRM domains need the same behavior:

- same field types
- same validation model
- same filter semantics
- same API and UI authoring flow

Until then:

- CRM keeps `Crm::FieldDefinition`
- scheduling keeps its current `custom_attributes` pattern
- config entities stay mostly explicit-column driven

### Why Not Reuse `CustomAttributeDefinition`

Do not extend the existing `CustomAttributeDefinition` table for CRM because it already encodes contact/conversation assumptions:

- only two attribute models exist today
- it has its own standard-attribute conflict list
- it has widget/pre-chat side effects
- it does not model task contexts or future pipeline/stage applicability

CRM needs a separate field-definition surface, but the value-storage pattern can still remain native:

- stable core business state in first-class columns and associations
- tenant-specific metadata in `custom_attributes`

### Custom Field Rules

`Crm::FieldDefinition.rules` should remain typed and machine-readable.

Supported v1 responsibilities:

- `contexts`
- `filterable`
- `searchable`
- `read_only`
- `min`
- `max`
- `regex`
- `placeholder`
- `help_text`

Task-specific context support is required in v1:

- `standalone_task`
- `deal_task`

Meaning:

- one task model serves both standalone work and deal work
- field applicability is controlled by field-definition rules, not by splitting tasks into separate models

Future-safe reserved expansion:

- pipeline-specific deal fields
- stage-specific deal fields
- task presets and templates

Those future capabilities should extend `rules`, not require a redesign of `Task` or `Deal`.

### Custom Field Write Rules

- write payloads may include `custom_attributes`
- unknown keys must be rejected with validation error
- inactive fields remain readable for existing records but are not writable
- default values apply on create, not retroactively
- removing a field definition must not silently delete stored values from historical records

### Example: Task Field That Only Applies Inside a Deal

```json
{
  "entity_kind": "task",
  "key": "follow_up_reason",
  "label": "Follow-up reason",
  "field_type": "select",
  "required": true,
  "options": ["pricing", "documents", "approval"],
  "rules": {
    "contexts": ["deal_task"],
    "filterable": true,
    "searchable": false
  }
}
```

That is the intended native pattern:

- one shared `Task` model
- one shared custom-field system
- context-aware applicability

## Lifecycle Semantics

### Deal Lifecycle

Supported v1 lifecycle actions:

- create
- update
- transition stage
- archive
- unarchive

Rules:

- deal state is determined by pipeline plus stage
- moving to a `won` or `lost` stage sets `closed_at`
- moving back to an `open` stage clears `closed_at`
- every stage transition writes a `Crm::Event`
- stage changes must go through a dedicated transition service, not generic mass assignment

### Task Lifecycle

Supported v1 lifecycle actions:

- create
- update
- change status
- archive
- unarchive

Rules:

- task may exist without a deal
- if linked to a deal, it remains its own aggregate with its own status and assignee
- moving to a `done` status sets `completed_at`
- moving back to an `open` status clears `completed_at`
- every status change writes a `Crm::Event`
- status changes must go through a dedicated transition service

### Interaction Between Deals and Tasks

Rules:

- deal-linked tasks are first-class tasks, not nested sub-documents on the deal
- closing a deal does not automatically complete or archive open tasks in v1
- deal detail should expose related tasks as a dedicated section
- task detail should expose its linked deal summary when `deal_id` is present

This keeps behavior predictable and leaves room for future automation without baking in premature side effects.

### Contact Lifecycle and Deal Outcomes

Rules:

- CRM may link any contact regardless of `contact_type`
- `crm_v2` continues to affect current contact selection semantics where it already exists
- deal creation or winning a deal does not mutate `Contact.contact_type`
- if later required, contact promotion must be explicit, audited, and behind its own service and product rule

### Company Behavior

Rules:

- `company_id` on a deal is optional but first-class
- if the caller omits `company_id` and the primary contact has a single obvious company, the service may default it
- `company_id` improves search, filtering, and account-level reporting
- `company_id` does not expand conversation/message visibility
- company association should never be mandatory for deal creation

## Timeline, Comments, and Activity

Do not build one giant generic `Activity` table before the behavior is stable.

Use three separate pieces:

- `Crm::Event` for structured lifecycle events
- `Crm::Comment` for human discussion
- filtered related conversations for message history

### Deal Timeline

The deal timeline may include:

- deal events
- deal comments
- related conversation summaries and optional excerpts

Conversation inclusion rules:

- include `originating_conversation_id` when present
- include conversations for linked contacts when useful
- deduplicate conversation ids
- filter through the existing conversation permission filter service before serializing
- do not expand by `company_id` alone

### Task Timeline

The task timeline should include:

- task events
- task comments
- the originating conversation summary when `originating_conversation_id` is present and visible to the actor

Conversation inclusion rules for task timeline:

- include at most the explicitly linked `originating_conversation_id`
- filter through the existing conversation permission filter service before serializing
- do not automatically expand by linked deal contacts
- do not automatically expand by company association
- do not pull broad conversation history by default in v1

### User Timeline vs Compliance Audit

These are different concerns.

- `Crm::Event` is for user-facing history
- account-level audit trails are for compliance and admin traceability

Configuration entities such as pipelines, stages, task statuses, and field definitions should follow the existing audit pattern used elsewhere in the codebase. User-facing activity should remain in `Crm::Event`.

## API and Controller Contract

### Base Pattern

CRM controllers should follow the same shape as `scheduling`:

- `Api::V1::Accounts::Crm::BaseController`
- feature gating in `before_action`
- `render_payload`
- `render_error`
- typed CRM domain errors
- standard rescue handling for record invalid, not found, unique conflicts, stale object conflicts, and bad params

Recommended CRM error codes:

- `FEATURE_DISABLED`
- `VALIDATION_ERROR`
- `DUPLICATE_EXTERNAL_REF`
- `DUPLICATE_IDEMPOTENCY_KEY`
- `INVALID_TRANSITION`
- `STALE_RECORD`
- `NOT_FOUND`

### Payload Building

Add `Crm::PayloadBuilder` to serialize:

- deals
- tasks
- pipelines
- stages
- task statuses
- comments
- events
- compact related contact/company/user summaries

Payload builders should:

- emit stable JSON contracts
- preload relations to avoid N+1s
- serialize timestamps in ISO 8601
- return `custom_attributes` exactly as stored

### Recommended Routes

`/api/v1/accounts/:account_id/crm/pipelines`

- `index`
- `show`
- `create`
- `update`

`/api/v1/accounts/:account_id/crm/pipelines/:pipeline_id/stages`

- `create`
- `update`

`/api/v1/accounts/:account_id/crm/deals`

- `index`
- `show`
- `create`
- `update`

`/api/v1/accounts/:account_id/crm/deals/:id`

- `archive`
- `unarchive`

`/api/v1/accounts/:account_id/crm/deals/:id/transition_stage`

- `create`

`/api/v1/accounts/:account_id/crm/deals/:deal_id/contacts`

- `create`
- `destroy`

`/api/v1/accounts/:account_id/crm/deals/:deal_id/comments`

- `index`
- `create`
- `update`
- `destroy`

`/api/v1/accounts/:account_id/crm/deals/:deal_id/timeline`

- `index`

`/api/v1/accounts/:account_id/crm/tasks`

- `index`
- `show`
- `create`
- `update`

`/api/v1/accounts/:account_id/crm/tasks/:id`

- `archive`
- `unarchive`

`/api/v1/accounts/:account_id/crm/tasks/:id/change_status`

- `create`

`/api/v1/accounts/:account_id/crm/tasks/:task_id/comments`

- `index`
- `create`
- `update`
- `destroy`

`/api/v1/accounts/:account_id/crm/tasks/:task_id/timeline`

- `index`

`/api/v1/accounts/:account_id/crm/task_statuses`

- `index`
- `create`
- `update`

`/api/v1/accounts/:account_id/crm/field_definitions`

- `index`
- `create`
- `update`
- `destroy`

### Write Payload Rules

Deal create and update payloads should accept:

- system fields as first-class params
- `contact_ids`
- `primary_contact_id`
- `custom_attributes`

Task create and update payloads should accept:

- system fields as first-class params
- optional `deal_id`
- optional `originating_conversation_id`
- `custom_attributes`

Write services must reject:

- unknown custom-field keys
- custom fields not allowed in the current task context
- cross-account ids
- raw writes to managed timestamps such as `closed_at` and `completed_at`

## Query, Search, and View Semantics

Do not extend the old generalized filter layer for CRM v1.

Use dedicated query services:

- `Crm::Deals::IndexQuery`
- `Crm::Tasks::IndexQuery`
- `Crm::Deals::TimelineQuery`
- `Crm::Tasks::TimelineQuery`

### Deal Views

Supported projections:

- list
- kanban

Default filters:

- exclude archived deals
- scope to current account

Recommended filters:

- `pipeline_id`
- `stage_id`
- `owner_id`
- `team_id`
- `company_id`
- `contact_id`
- `expected_close_from`
- `expected_close_to`
- `closed_from`
- `closed_to`
- `include_archived`
- `q`

### Task Views

Supported projections:

- list
- kanban
- calendar

Default filters:

- exclude archived tasks
- scope to current account

Recommended filters:

- `status_id`
- `assignee_id`
- `creator_id`
- `team_id`
- `deal_id`
- `standalone_only`
- `deal_tasks_only`
- `due_from`
- `due_to`
- `start_from`
- `start_to`
- `include_archived`
- `q`

Calendar rules:

- calendar range queries should use `due_from` and `due_to`
- use `due_at` as the default calendar anchor in v1
- tasks without `due_at` are not part of the calendar projection in the first runtime slice
- frontend day, week, and month calendar views may derive `due_from` and `due_to` from the shared scheduling date-range helpers

### Pagination Rules

- list endpoints use `page` and `per_page`
- `per_page` must have a hard max of `100`
- timeline endpoints use cursor pagination
- kanban endpoints must support per-group item caps

### Search Semantics

CRM-local search should cover:

- record title
- description
- external ref
- linked contact name
- linked company name or domain

If custom fields are marked searchable in the field catalog, query services may include them.

Do not force CRM search into the existing global `SearchService` in v1. Add global search integration later through a dedicated CRM search adapter.

### Kanban Semantics

Kanban should be a grouped projection, not a separate persistence model.

Rules:

- group by stage for deals
- each group returns items plus total count
- support per-group pagination or item caps
- do not return unbounded records for every stage in one request

## Idempotency, Concurrency, and Reliability

Reliability is a hard requirement.

### Required Patterns

- every CRM table is account-scoped
- writes happen in explicit services
- transitions happen in dedicated services
- multi-record writes use transactions
- unique conflicts return typed 409 errors where appropriate

### Entity-Level Idempotency

`Crm::Deal` and `Crm::Task` should support:

- `external_ref`
- `idempotency_key`

Rules:

- uniqueness is enforced per account
- values are optional
- these fields support imports, hooks, retry-safe requests, and future integrations

### Optimistic Locking

Add `lock_version` to:

- `Crm::Deal`
- `Crm::Task`

Rules:

- update and transition services should honor optimistic locking
- stale writes return `STALE_RECORD`
- UI can retry by reloading the latest record

### Transition Safety

Stage and status changes should:

- lock the record being transitioned
- validate same-account target config
- create one event row inside the same transaction

### Callback Discipline

Do not attach CRM side effects to callbacks on:

- `Contact`
- `Conversation`
- `Company`

If CRM must react to changes elsewhere, do it through explicit services or background listeners after commit.

## Indexing and Persistence Contract

Recommended indexes:

- pipelines:
  - unique on `account_id, code`
  - unique partial default index on `account_id` where `default = true`
- stages:
  - unique on `pipeline_id, code`
  - index on `account_id, pipeline_id, position`
- deals:
  - unique partial on `account_id, external_ref` where `external_ref is not null`
  - unique partial on `account_id, idempotency_key` where `idempotency_key is not null`
  - partial index on `account_id, pipeline_id, stage_id, owner_id, expected_close_on` where `archived_at is null`
  - index on `account_id, company_id`
  - index on `account_id, team_id`
  - index on `account_id, originating_conversation_id`
  - optional GIN on `custom_attributes`
- deal contacts:
  - unique on `deal_id, contact_id`
  - unique partial on `deal_id` where `primary = true`
  - index on `account_id, contact_id`
- task statuses:
  - unique on `account_id, code`
  - unique partial default index on `account_id` where `default = true and category = 'open'`
- tasks:
  - unique partial on `account_id, external_ref` where `external_ref is not null`
  - unique partial on `account_id, idempotency_key` where `idempotency_key is not null`
  - partial index on `account_id, status_id, assignee_id, due_at` where `archived_at is null`
  - index on `account_id, deal_id`
  - index on `account_id, team_id`
  - optional GIN on `custom_attributes`
- comments:
  - index on `account_id, commentable_type, commentable_id, created_at`
- events:
  - index on `account_id, eventable_type, eventable_id, created_at`
- field definitions:
  - unique on `account_id, entity_kind, key`
  - index on `account_id, entity_kind, active, position`

Notes:

- GIN on `custom_attributes` is useful for flexible filtering, but hot fields should be promoted to first-class columns if query pressure justifies it
- if free-text `q` becomes hot, add targeted trigram indexes rather than one oversized generic search query

## Bootstrap and Defaults

CRM settings should not rely on manual SQL or ad hoc seeds.

Add an idempotent bootstrap service, for example:

- `Crm::Bootstrap::AccountService`

Responsibilities:

- create a default deal pipeline when `crm_deals` is enabled and the account has none
- create default stages for that pipeline
- create default task statuses when `crm_tasks` is enabled and the account has none
- remain safe to call multiple times

Suggested default deal stages:

- `new`
- `qualified`
- `proposal`
- `won`
- `lost`

Suggested default task statuses:

- `todo`
- `in_progress`
- `done`

Bootstrap should be feature-aware and idempotent. It must not run heavy logic on every request.

## Events, Integrations, and Automation

### Internal Domain Events

After successful commits, emit domain events such as:

- `crm.deal.created`
- `crm.deal.updated`
- `crm.deal.stage_changed`
- `crm.deal.archived`
- `crm.task.created`
- `crm.task.updated`
- `crm.task.status_changed`
- `crm.task.archived`
- `crm.field_definition.updated`

Rules:

- publish after commit
- payloads contain ids and typed snapshots, not AR objects
- outbound hooks and listeners must be async
- request latency must not depend on downstream webhooks

### External Integrations

Incoming external upsert/import flows should use the same write services as first-party flows whenever possible.

Rules:

- no parallel second write path
- prefer `external_ref` and `idempotency_key`
- new provider integrations go under `Integrations::Crm::*`

## Reporting Readiness

CRM v1 does not need to ship a full reporting product, but the schema must be reporting-grade.

That is why the following remain first-class fields:

- deal pipeline and stage
- deal amount and currency
- deal owner and team
- deal expected close date and closed date
- task status
- task assignee and creator
- task due date and completed date

Custom fields may participate in filtered views, but cross-account reporting must not depend on every important metric living only in JSON.

## Explicit Anti-Patterns

Do not do the following:

- do not introduce `crm_v3` as the main rollout flag
- do not repurpose `crm_v2` into "new CRM runtime"
- do not store deals as conversation metadata
- do not model tasks as a serialized array on deals
- do not overload `Note` for deal or task comments
- do not extend `CustomAttributeDefinition` for CRM v1
- do not derive CRM access from conversation permissions
- do not use `AccountUser` ids in owner or assignee fields
- do not make `company_id` mandatory
- do not bypass existing conversation permission filtering when showing CRM timelines
- do not add CRM write side effects into `Contact` or `Conversation` callbacks

## Suggested Delivery Order

### Phase 1: Settings Foundation

- feature flags
- policies
- pipelines and stages
- task statuses
- field definitions
- bootstrap service

### Phase 2: Deals

- deal model and joins
- create, update, transition, archive
- index, show, kanban
- payload builder
- base policy scope

### Phase 3: Tasks

- task model
- create, update, change status, archive
- list and calendar projections
- standalone and deal-linked task behavior

### Phase 4: Timeline and Collaboration

- comments
- events
- deal timeline with filtered conversation context
- task timeline

### Phase 5: Automation and Imports

- outbound events
- inbound upsert/import flows
- UI polish
- global search integration if justified

## Test Contract

Minimum required coverage:

- model specs for validation, scoping, enum behavior, and unique constraints
- policy specs for administrators, plain agents, and custom-role agents
- service specs for create, update, transition, archive, bootstrap, and idempotency
- request specs for payload shape, permission failures, feature-disabled failures, and conflict errors
- query specs for filtering, pagination, search, and timeline composition

Must-have scenarios:

- cross-account isolation on every relation
- `crm_v2` continues to behave as before
- stale update returns `STALE_RECORD`
- duplicate `external_ref` returns 409
- duplicate `idempotency_key` returns 409
- deal timeline respects conversation visibility
- standalone task and deal-linked task use the same task model correctly
- custom field validation rejects unknown keys and disallowed contexts
- archived records stay out of default queries
- company defaulting from primary contact is safe and not over-eager

## Final Architecture Decision

The native Onelink CRM should be:

- one shared runtime in `app/`
- separate first-class `Deal` and `Task` aggregates
- account-scoped and Pundit-authorized
- feature-gated by capability, not by version-number flags
- backed by dedicated configuration entities for pipelines, stages, task statuses, and CRM field definitions
- extensible through a merged field catalog, not through weakening core relations into generic JSON
- reliable under retries and concurrent edits through idempotency, optimistic locking, and explicit transition services

That shape is the best fit for the current project because it extends the codebase's existing strengths instead of fighting them.
