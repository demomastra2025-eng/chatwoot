# Native SMM/Postiz Module Implementation Plan

> **For Hermes:** Implement in an isolated feature branch and keep Postiz credentials server-side only. Do not deploy or restart runtime services unless explicitly approved.

**Goal:** Add a native OneLink SMM module that lets users connect social channels, view/schedule posts, upload media, and inspect basic analytics through OneLink UI while Postiz remains the publishing engine.

**Architecture:** Vue dashboard calls account-scoped Rails API under `/api/v1/accounts/:account_id/content/*`. Rails validates feature/access, reads the account-scoped encrypted `Integrations::Hook` for `postiz`, and calls Postiz Public API from the server via `Content::Postiz::Client`. The browser never receives the Postiz API key.

**Tech Stack:** Rails controllers/services/request specs, `Integrations::Hook`, Vue 3 dashboard routes/API/Pinia, existing sidebar visibility/feature flags, Postiz Public API at `POSTIZ_BASE_URL`.

---

## Scope

### MVP implementation

1. `postiz` integration catalog entry hidden/feature-gated.
2. Backend Postiz client with normalized error handling, timeout, and server-side credentials.
3. Account-scoped Content API:
   - connection show/update/destroy/test
   - channels index/oauth_url/destroy
   - posts index/create/destroy/status
   - media upload/upload_from_url
   - analytics index and post analytics
4. Native dashboard route `/app/accounts/:accountId/smm` with tabs:
   - Calendar
   - Posts
   - Channels
   - Media
   - Analytics
   - Settings
5. Frontend API clients and Pinia store.
6. Narrow backend/request and frontend utility tests where practical.

### Explicit non-goals for MVP

- Do not iframe Postiz as product UI.
- Do not expose Postiz API key to browser.
- Do not implement automatic Postiz organization provisioning unless a provisioning API/flow is proven.
- Do not deploy/restart prod/dev services in this branch task.

---

## Backend tasks

### Task 1: Add Postiz integration app definition

**Files:**
- Modify: `config/integration/apps.yml`

**Steps:**
1. Add `postiz` account-scoped integration app with `access_token_required: true`, `allow_multiple_hooks: false`, `hidden_in_ui: true`, and settings for `organization_id`, `default_timezone`.
2. Keep API key in `Integrations::Hook#access_token` only.
3. Do not return token in visible properties.

**Verification:** YAML parse and integration app load test/request coverage.

### Task 2: Add Content feature flag

**Files:**
- Modify: `config/features.yml`
- Modify: frontend feature flag constants if required by current pattern

**Steps:**
1. Add a new `content`/`content_planner` flag at the end to preserve legacy bit positions.
2. Wire dashboard visibility to the flag.

**Verification:** Feature flag config parses and sidebar visibility utility handles it.

### Task 3: Implement `Content::Postiz::Client`

**Files:**
- Create: `app/services/content/postiz/client.rb`
- Create: `app/services/content/postiz/error.rb`
- Test: `spec/services/content/postiz/client_spec.rb`

**Steps:**
1. Build HTTP client calls with `Authorization: <api_key>` header, not Bearer.
2. Resolve base URL from `POSTIZ_BASE_URL`, falling back to the internal default.
3. Restrict default production base URL to internal/local service URL; avoid arbitrary browser-provided URLs.
4. Add timeouts: connect 2-3s, read 10-15s.
5. Normalize errors: unavailable, unauthorized, validation, rate-limited, upstream.
6. Provide methods for integrations, OAuth URL, posts, status, upload, analytics, health/test.

**Verification:** Unit specs stub Faraday and assert header shape, URL shape, and error mapping.

### Task 4: Add account-scoped Content controllers

**Files:**
- Create: `app/controllers/api/v1/accounts/content/base_controller.rb`
- Create: `app/controllers/api/v1/accounts/content/connections_controller.rb`
- Create: `app/controllers/api/v1/accounts/content/channels_controller.rb`
- Create: `app/controllers/api/v1/accounts/content/posts_controller.rb`
- Create: `app/controllers/api/v1/accounts/content/media_controller.rb`
- Create: `app/controllers/api/v1/accounts/content/analytics_controller.rb`
- Modify: `config/routes.rb`
- Test: `spec/requests/api/v1/accounts/content/*_spec.rb`

**Steps:**
1. In `BaseController`, enforce account scope, feature flag, and hook lookup.
2. Keep response envelopes stable: `{ data: ... }` or `{ error: { code, message, details } }`.
3. Use hook access token server-side.
4. Implement create/update/destroy settings without ever serializing token back.
5. Proxy only whitelisted Postiz endpoints.

**Verification:** Request specs for no hook, unauthorized Postiz, channels list, posts create payload, and token redaction.

---

## Frontend tasks

### Task 5: Add dashboard API layer and store

**Files:**
- Create: `app/javascript/dashboard/api/content/connection.js`
- Create: `app/javascript/dashboard/api/content/channels.js`
- Create: `app/javascript/dashboard/api/content/posts.js`
- Create: `app/javascript/dashboard/api/content/media.js`
- Create: `app/javascript/dashboard/api/content/analytics.js`
- Create: `app/javascript/dashboard/stores/content.js`

**Steps:**
1. Reuse existing dashboard API client pattern.
2. Keep all requests account-scoped.
3. Normalize loading/error flags in Pinia.

**Verification:** Existing import/build checks and narrow store tests if current repo has nearby patterns.

### Task 6: Add native Content route and sidebar entry

**Files:**
- Create: `app/javascript/dashboard/routes/dashboard/content/routes.js`
- Modify: `app/javascript/dashboard/routes/dashboard/dashboard.routes.js`
- Modify: `app/javascript/dashboard/components-next/sidebar/Sidebar.vue`
- Modify: `app/javascript/dashboard/components-next/sidebar/sidebarVisibility.js`
- Modify: locale files for `CONTENT.*` labels

**Steps:**
1. Add `/content` route under account dashboard.
2. Gate visibility by feature flag and permissions/access pattern used by nearby modules.
3. Add Russian and English labels at minimum.

**Verification:** Route import compiles and sidebar visibility helper tests pass where present.

### Task 7: Build Content pages

**Files:**
- Create: `app/javascript/dashboard/routes/dashboard/content/ContentHome.vue`
- Create: `app/javascript/dashboard/routes/dashboard/content/pages/ContentCalendarPage.vue`
- Create: `app/javascript/dashboard/routes/dashboard/content/pages/ContentPostsPage.vue`
- Create: `app/javascript/dashboard/routes/dashboard/content/pages/ContentChannelsPage.vue`
- Create: `app/javascript/dashboard/routes/dashboard/content/pages/ContentSettingsPage.vue`
- Create: `app/javascript/dashboard/routes/dashboard/content/components/ContentComposerModal.vue`

**Steps:**
1. Provide a usable shell first: tabs, empty/error states, loading states.
2. Calendar fetches posts by date window.
3. Channels page lists integrations and opens OAuth URL in a new tab/popup.
4. Composer builds simple schedule/draft/now payload and lets backend assemble/validate Postiz shape.
5. Settings page stores API key via backend only; do not echo existing token.

**Verification:** Scoped ESLint/build checks and manual dev smoke when approved.

---

## Operational notes

- Postiz Public API key is not a OneLink-paid license by itself. For self-hosted Postiz it is an API token generated inside Postiz/workspace settings and used to authorize Public API calls. If Postiz Cloud is used, pricing/plan limits may apply on the Postiz side, but the key is still required for API auth. OneLink should store it encrypted per account or use a service-owned key for MVP if product chooses single-org mode.
- Current local Postiz endpoint observed: `http://127.0.0.1:4007/public/v1`.
- Before production use, bind Postiz to localhost/internal network or protect it behind reverse proxy; avoid `0.0.0.0` exposure.

---

## Verification pack

1. `ruby -c` for new Ruby files.
2. `bundle exec rspec spec/services/content/postiz/client_spec.rb spec/requests/api/v1/accounts/content` with service env.
3. `pnpm exec eslint <changed frontend files>`.
4. Narrow Vitest if frontend logic tests are added.
5. `git diff --check`.
6. Independent review before commit/push.
