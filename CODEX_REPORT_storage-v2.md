# Storage v2 implementation and verification

## Read workflow

- Account storage overview and refresh responses serve the last Redis snapshot. Cold reads return `calculating: true` without inventing zero physical usage. Refresh responses expose `refresh_status` (`queued`, `pending`, `failed`) and return HTTP 503 when enqueue fails. Snapshot responses also expose `refresh_pending` and `stale`.
- Heavy recording rows are read from the current account's call sessions. Inbox, conversation and date predicates apply before the size sort and limit; the global top-200 compatibility snapshot is no longer the source of filtered results. Playback URLs are signed from the current recording reference.
- Missing legacy sizes make a recording list explicitly incomplete. Available rows remain visible. A database failure returns an error rather than a false empty result. The page suppresses “No files found” while incomplete and polls pending work every ten seconds.
- Overview, heavy files, quota reads, trash listing, and the default `Account#storage_breakdown` used by admin pages/export perform no recording filesystem traversal. The signed cleanup-preview manifest remains the existing audited workflow: it resolves/stats selected files before explicit confirmation. Its exact manifest is shared in Redis for five minutes so another web worker can redeem the signed token; missing/corrupt manifests fail closed. Token signature, actor, account, filters, digest and current-selection revalidation remain required. That preview/action workflow was not replaced by asynchronous selection in this change.
- The page guards overview, file-list, trash and preview responses by request sequence and account. Move, restore, restore-all, purge and empty-trash reload the visible list. An older request cannot replace the post-action rows or end a newer loading state.

## Background accounting and freshness

- Normal accounting uses size metadata populated by recording ingestion and compression: `recording.byte_size`, `recording.retained_original.byte_size`, session trash manifests, and retained-original trash sizes.
- A shared Redis reconciliation performs one streaming tenant filesystem pass on a cold inventory, after 24 hours, or when new legacy primary references lack size metadata. It includes unlinked files and trash, excludes foreign paths/symlinks, and deduplicates hard links by inode. Size metadata is not summed and labelled as verified physical usage on its own.
- Between reconciliations, totals use current native sizes, unchanged fallback measurements and the cached unlinked files. A newly linked file is removed from the unlinked bucket so it is counted once. Trash manifests reuse the original physical identity through their original path/storage key. Out-of-band file changes are discovered on the next physical reconciliation; `recordings_reconciled_at` identifies that audit time.
- Fallback samples are additive `metadata.storage_metrics` fields. They identify the measured account, canonical tenant key, reference, size, declared size at measurement, physical identity and timestamp. Ruby and SQL accept a measurement only when its tenant key matches the exact current reference or bare legacy basename, and its bounded numeric timestamp is within the last 24 hours. Old proofless samples trigger a background reconciliation. Foreign/remote references are excluded without forcing repeated missing-size audits. Writes compare the original session reference and metadata to avoid overwriting concurrent ingestion/compression/trash changes. Reusing a measurement does not redate it or rewrite every call session.
- Quota reads keep the last background recording total and request work on a cold cache. With no measured recording total ever available they retain the historical zero fallback; the storage page itself shows pending rather than a completed zero measurement. Local recordings still participate in upload quota only under the existing `STORAGE_QUOTA_INCLUDE_RECORDINGS` opt-in.
- Data mutations advance a per-account generation. One atomic Redis publication checks both generation and worker lease before writing the overview, compatibility recording cache, physical reconciliation and seven-day last good total. There are no later process-local total writes that an obsolete worker could use to overwrite newer values. Quota reads prefer the shared snapshot and use the shared last good total when no snapshot can be read. Superseded calculations retain the last snapshot and schedule a successor.
- The old one-hour pending marker is replaced by a v2 five-minute lease, renewed during long reconciliation work. An abandoned lease expires. A queued job that lost its lease skips work, and a former worker cannot release another worker's lease.
- There is no transaction around the filesystem pass. All worker and heavy-list SQL uses a ten-second session `statement_timeout`, restored in `ensure`, including failure paths. Production's 30-second statement and 60-second idle-transaction defaults remain compatible.

## Verification

Local frontend checks passed: 26 tests in `Index.spec.js`, `storageFormatters.spec.js`, `storage.routes.spec.js` and `StorageUsageBanner.spec.js`, with `TZ=UTC`, one worker. The settings tests cover response/error races, account changes, all five cleanup actions, recording label/icon, incomplete/error states, truthful refresh notification and automatic pending completion. The first formatter run without UTC failed on the unchanged expected timezone; the repository's UTC setting resolved it.

Focused ESLint checked the settings component and spec without errors. Existing localization-resource/dynamic-key warnings remain outside the error-level check. Local Ruby Prism parsing checks syntax only; it does not validate PostgreSQL execution or Ruby behavior.

The following runtime specs are ready for the isolated PostgreSQL/Redis/pgvector harness:

```sh
bundle exec rspec \
  spec/services/accounts/heavy_files_service_spec.rb \
  spec/services/accounts/heavy_recordings_snapshot_spec.rb \
  spec/services/accounts/storage_overview_service_spec.rb \
  spec/services/storage/recording_inventory_spec.rb \
  spec/services/storage/recording_metadata_spec.rb \
  spec/services/storage/trash_service_spec.rb \
  spec/models/account_storage_breakdown_spec.rb \
  spec/services/account_limits/storage_usage_service_spec.rb \
  spec/models/concerns/account_storage_limitable_spec.rb \
  spec/requests/api/v1/accounts/storage_spec.rb \
  spec/services/telephony/recording_compression_service_spec.rb \
  spec/jobs/telephony/purge_retained_recordings_job_spec.rb \
  spec/controllers/super_admin/accounts_controller_spec.rb
```

New Ruby risk checks cover filtering a recording below 205 larger rows, live links after compression, trash/restore/purge without waiting for snapshots, real `connection.open_transactions` observations at SQL/file-scan boundaries, timeout restoration, abandoned/lost leases, generation races, incomplete size metadata, stereo/retained/trash files, duplicate paths/hard links, tenant boundaries, shared reconciliation freshness and preservation of last physical totals on failure.

## Delivery boundary

No schema migration or dependency was added. No application server, historical compression batch, integration branch, remote push or deployment was changed by this implementation. The docs submodule is empty in this local worktree; this report documents the existing workflow and new API/freshness contract for the release review. Runtime test and independent review results must be appended by the release owner before promotion.
