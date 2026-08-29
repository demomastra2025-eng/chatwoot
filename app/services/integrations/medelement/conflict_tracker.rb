class Integrations::Medelement::ConflictTracker
  def initialize(sync_run:)
    @sync_run = sync_run
  end

  def record!(phase:, entity_type:, conflict_type:, entity_key:, **options)
    entity_key_digest = Integrations::Medelement::ErrorSanitizer.digest(entity_key)
    fingerprint = conflict_fingerprint(phase, entity_type, conflict_type, entity_key_digest)
    attributes = {
      phase: phase,
      entity_type: entity_type,
      conflict_type: conflict_type,
      severity: options.fetch(:severity, 'warning'),
      details: options.fetch(:details, {})
    }

    persist_conflict(fingerprint, entity_key_digest, attributes)
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def resolve_absent!(phase, entity_keys: nil)
    scope = conflict_scope.open.where(phase: phase).where.not(last_sync_run_id: sync_run.id)
    if entity_keys
      entity_key_digests = entity_keys.map { |entity_key| Integrations::Medelement::ErrorSanitizer.digest(entity_key) }
      scope = scope.where(entity_key_digest: entity_key_digests)
    end
    scope.find_each(&:resolve_automatically!)
  end

  private

  attr_reader :sync_run

  def conflict_fingerprint(phase, entity_type, conflict_type, entity_key_digest)
    Integrations::Medelement::ErrorSanitizer.digest(
      [sync_run.account_id, sync_run.hook_id, phase, entity_type, conflict_type, entity_key_digest].join(':')
    )
  end

  def persist_conflict(fingerprint, entity_key_digest, attributes)
    Integrations::Medelement::SyncConflict.transaction(requires_new: true) do
      conflict = conflict_scope.lock.find_or_initialize_by(fingerprint: fingerprint)
      assign_conflict(conflict, entity_key_digest, attributes)
      conflict.save!
      conflict
    end
  end

  def assign_conflict(conflict, entity_key_digest, attributes)
    now = Time.current
    conflict.assign_attributes(
      attributes.merge(
        hook: sync_run.hook,
        entity_key_digest: entity_key_digest,
        details: Integrations::Medelement::ErrorSanitizer.sanitize_details(attributes[:details]),
        first_sync_run: conflict.first_sync_run || sync_run,
        last_sync_run: sync_run,
        first_seen_at: conflict.first_seen_at || now,
        last_seen_at: now,
        occurrences: conflict.persisted? ? conflict.occurrences + 1 : 1
      )
    )
    reopen_resolved_conflict(conflict)
  end

  def reopen_resolved_conflict(conflict)
    conflict.status = 'open' if conflict.new_record? || conflict.resolved?
    return unless conflict.open?

    conflict.resolved_at = nil
    conflict.resolution_note = nil
  end

  def conflict_scope
    Integrations::Medelement::SyncConflict.where(account_id: sync_run.account_id, hook_id: sync_run.hook_id)
  end
end
