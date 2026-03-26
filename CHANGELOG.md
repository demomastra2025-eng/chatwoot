# Changelog

## 2026-03-26

- fix(email): unify inbox SMTP TLS settings across validation and delivery, and disable hostname verification when an inbox explicitly uses `smtp_openssl_verify_mode = none` so shared-cert STARTTLS servers no longer fail reply sends on Ruby 3.4
- fix(macrocrm): create new WhatsApp deals without `manager_id` and stop fallback Chatwoot assignment overrides so Onelink routing remains the source of truth unless MacroCRM explicitly returns a manager
- fix(medelement): continue sync past invalid reception rows, keep their external refs out of cleanup deletions, and log skipped rows instead of aborting the whole import
- fix(medelement): add database-level unique indexes for Medelement patient and specialist codes so contact/resource dedupe is enforced beyond application logic

## 2026-03-23

- fix(medelement): seed imported specialists with a business-hours default schedule of Mon-Fri `09:00-18:00`, Sat `09:00-15:00`, Sun off, and upgrade existing legacy `24/7` auto-seeded Medelement schedules in place
- fix(scheduling): keep timeline calendars wide enough to render imported appointments that fall outside configured working-hour slots instead of clipping them out of view
- fix(timezones): update Ruby timezone data so `Asia/Almaty` resolves globally as UTC+05, including Medelement imports and scheduling resources
- fix(scheduling): auto-scroll day/week vue-cal timelines on open via the native `scrollToCurrentTime` / `scrollToTime` API
- fix(scheduling): ignore stale calendar responses so rapid employee-filter changes stop showing all employees under a narrower selection

## 2026-03-19

- feat(captain): add native Firecrawl-powered file URL imports for Captain Documents so assistants can ingest supported remote Word and Excel files without changing the existing PDF upload or runtime response pipeline

## 2026-03-18

- fix(captain): force Captain embeddings onto 1536 dimensions for `text-embedding-3-*` models so FAQ search and embedding updates stay compatible with the existing pgvector columns
- fix(captain): return a safe tool result when documentation lookup fails so assistant playground requests do not crash with follow-up `tool_calls` 500 errors
- fix(captain): stop sending the current playground message twice, reducing duplicated prompts and flaky assistant behavior between turns
- fix(captain): move the create-assistant action out of the switcher modal into the Captain header so it stays visible next to the current assistant selector
- fix(captain): place the create-assistant button after the assistant switcher chevron and align the message collapse/history limit fields on one row in assistant forms
- fix(captain): keep assistant playground requests from surfacing as 500s when an LLM response exceeds the rack timeout, and raise the production rack timeout budget to 30 seconds for long Captain responses
- fix(settings): keep the profile settings page inside the dashboard scroll container so long content no longer pushes past the visible interface
- fix(email): respect `imap_enable_ssl` when polling inboxes so IMAP accounts configured on port `143` without implicit TLS stop failing with SSL record-layer errors
- fix(selects): stop teleported combobox dropdown clicks from being treated as backdrop/outside clicks so parent modals stay open while only the select closes

## 2026-03-17

- fix(whatsapp-web): normalize imported history attachment MIME types from actual file contents before attaching, so non-image payloads are not misclassified as JPEG/PNG and sent through image analysis incorrectly
- fix(whatsapp-web): refetch provider records before giving up on history attachment imports, so stale Evolution history snapshots can still resolve media through the native provider fallback path
