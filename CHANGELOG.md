# Changelog

## 2026-03-17

- fix(whatsapp-web): normalize imported history attachment MIME types from actual file contents before attaching, so non-image payloads are not misclassified as JPEG/PNG and sent through image analysis incorrectly
- fix(whatsapp-web): refetch provider records before giving up on history attachment imports, so stale Evolution history snapshots can still resolve media through the native provider fallback path
