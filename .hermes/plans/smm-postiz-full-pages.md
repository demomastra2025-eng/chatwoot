# OneLink SMM/Postiz Full Pages Implementation Plan

**Goal:** turn the existing MVP Postiz bridge into a usable OneLink SMM workspace covering calendar, posts, channels, media, analytics, and settings.

**Architecture:** keep Postiz API keys server-side in Rails, expose only account-scoped OneLink content endpoints to Vue, and render a native OneLink dashboard surface using existing components-next/Tailwind patterns. Do not copy Postiz React UI; adapt the contracts and UX concepts.

**Scope for this slice:** no production deploy/restart, no DB migrations, no direct external post creation during tests.

## Tasks

1. Backend bridge hardening
- Fix Postiz client successful-non-JSON status mapping.
- Add safe server-side bridge for channel best-slot lookup.
- Keep credentials server-side and account scoped.
- Verify with request specs/Ruby syntax.

2. Frontend data store
- Add Pinia actions for post delete/status/missing, channel delete/find-slot, media file/URL upload, and analytics.
- Keep response normalization centralized.
- Add UI flags for async actions.

3. Payload and helper layer
- Support image/media arrays in post payloads.
- Add helper functions for status labels/classes, date ranges, calendar grid, filtering, metrics, and analytics flattening.
- Cover payload/helpers with Vitest.

4. SMM pages UI
- Rebuild `SmmPage.vue` into tabbed full pages:
  - Calendar: month navigation, weekly grid, daily post cards, selected day panel, composer.
  - Posts: filters/search, status/channel filters, post actions, missing-content and analytics actions.
  - Channels: connected channels, OAuth provider cards, refresh/delete/find-slot actions.
  - Media: file upload, URL upload, uploaded media library for attachment.
  - Analytics: channel/post analytics loading and metric rendering.
  - Settings: connection status, token/settings save/test.
- Use existing OneLink classes/components, responsive layouts, no bare template copy from Postiz.

5. Verification
- Run focused Vitest for helper/payload specs.
- Run scoped ESLint for touched JS/Vue.
- Run Ruby syntax/request specs for content bridge where feasible.
- Run `git diff --check` and path-scoped diff review.
