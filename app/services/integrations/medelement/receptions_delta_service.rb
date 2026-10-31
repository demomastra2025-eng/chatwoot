class Integrations::Medelement::ReceptionsDeltaService
  OVERLAP = 3.minutes
  MAX_CHANGED = 200
  CURSOR_NAME = 'receptions_delta'.freeze
  IntegrationChangedError = Integrations::Medelement::DeltaPollGuard::IntegrationChangedError
  # The refusals of the importer for a single reception. The regular sync skips such a reception, the stale status
  # reconciliation too, and so does this poll: one bad reception must not stall the others.
  SKIPPED_ERRORS = [
    Integrations::Medelement::AppointmentSnapshotGuard::StaleSnapshotError,
    Integrations::Medelement::ReceptionsSyncService::InvalidReceptionError,
    Integrations::Medelement::ReceptionServiceRows::InvalidSnapshotError,
    ActiveRecord::RecordInvalid,
    Scheduling::Error
  ].freeze
  # What process_code gives back for a reception that the importer refused with one of SKIPPED_ERRORS.
  Skipped = Data.define(:reason)

  def initialize(hook:, client: nil, configuration: nil, renew_locks: nil)
    @hook = hook
    @poll_guard = Integrations::Medelement::DeltaPollGuard.new(hook: hook)
    @configuration = configuration || Integrations::Medelement::Configuration.new(hook: hook)
    @client = client || Integrations::Medelement::Client.new(configuration: @configuration, lane: :sync_near)
    @renew_locks = renew_locks
  end

  def perform
    return :disabled unless enabled?

    started_at = Time.current
    cursor = find_cursor
    initialize_lower_bound!(cursor)
    changes = changed_codes(cursor)
    counts = apply_codes(changes)
    finish_poll!(cursor, started_at, counts[:complete])
    log_poll(cursor, changes, counts)
    counts.merge(changed_codes: changes.size)
  end

  # The two steps that turn a fetched reception detail into an appointment change. The stale status reconciliation uses
  # them too, so that an old reception goes through exactly the checks and the import path of a polled change.
  def validate_detail!(detail, code)
    valid = detail.is_a?(Hash) && detail['RECEPTION_CODE'].to_s == code &&
            (detail['REMOVED'].to_i == 1 || (detail['SERVICES'].is_a?(Array) &&
              (detail['PROFILE_CODE'].presence || detail['PATIENT_CODE'].presence)))
    raise Integrations::Medelement::Client::ApiError, 'Medelement delta reception detail is incomplete' unless valid

    Integrations::Medelement::ProviderScope.validate_write!(detail, organization_id: configuration.organization_id)
  end

  # The detail has no cabinet. entry_cabinet_code is the cabinet the update list reported for the code, if it did.
  # An OutOfScope (with its reason) is returned for a reception the import refuses because its specialist or cabinet is not mapped.
  def apply_detail!(detail, entry_cabinet_code: nil, snapshot_version: nil)
    @poll_guard.synchronize do
      Integrations::Medelement::ReceptionsSyncService.new(
        account: hook.account, client: client, configuration: configuration
      ).import_reported_reception!(detail, entry_cabinet_code: entry_cabinet_code, snapshot_version: snapshot_version)
    end
  rescue Integrations::Medelement::ReceptionsSyncService::OutOfScopeReception => e
    Integrations::Medelement::ReceptionsSyncService::OutOfScope.new(reason: e.reason)
  end

  private

  attr_reader :hook, :client, :configuration

  def finish_poll!(cursor, started_at, complete)
    @poll_guard.synchronize do
      update_cursor!(cursor, started_at, complete)
      Integrations::Medelement::DeltaMissAudit.new(hook: hook).resolve_candidates!(poll_completed_at: Time.current) if complete
    end
  end

  def enabled?
    hook.enabled? && hook.feature_allowed? && configuration.sync_receptions? &&
      configuration.incremental_receptions_enabled?
  end

  def initialize_lower_bound!(cursor)
    cursor.update!(value: cursor.created_at - OVERLAP) unless cursor.value
  end

  def changed_codes(cursor)
    from = cursor.last_success_at ? cursor.value - OVERLAP : cursor.value
    entries = client.receptions_by_update_date(
      update_date_from: from.in_time_zone(configuration.time_zone).strftime('%d.%m.%Y %H:%M')
    )
    entries.group_by { |entry| reception_code!(entry) }.sort.to_h
  end

  def apply_codes(changes)
    applied = 0
    skipped = 0
    processed = 0
    complete = true
    prioritize_unseen_changes(changes).each do |code, entries|
      outcome = process_code(code, entries, processed)
      if outcome == :seen
        skipped += 1
        next
      end
      if outcome == :cap
        complete = false
        break
      end

      refused?(outcome) ? skipped += 1 : applied += 1
      processed += 1
    end

    { applied: applied, skipped: skipped, complete: complete }
  end

  def process_code(code, entries, processed)
    @renew_locks&.call
    return :seen if entries.all? { |entry| (marker = update_marker(entry)) && seen?(code, marker) }
    return :cap if processed >= MAX_CHANGED

    detail, marker, snapshot_version = fetch_detail(code)
    return :seen if seen?(code, marker)

    result = apply_or_skip(code, detail, entries, snapshot_version)
    mark_seen!(code, marker)
    Integrations::Medelement::ScheduleChangeTracker.new(hook: hook).mark_reception!(detail) unless refused?(result)
    result
  end

  def refused?(outcome)
    outcome.is_a?(Skipped) || outcome.is_a?(Integrations::Medelement::ReceptionsSyncService::OutOfScope)
  end

  # A reception that the importer refuses is logged and counted as skipped, and the poll goes on with the next code. It is marked
  # as handled for this change marker like any other: it is read again only when MedElement changes the reception.
  def apply_or_skip(code, detail, entries, snapshot_version)
    result = apply_detail!(detail, entry_cabinet_code: entry_cabinet_code(entries), snapshot_version: snapshot_version)
    result == :stale_snapshot ? Skipped.new(reason: :stale_snapshot) : result
  rescue *SKIPPED_ERRORS => e
    Rails.logger.warn(
      "[MEDELEMENT::DELTA] Skipping reception for hook=#{hook.id} " \
      "entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(code)} reason=#{e.class}"
    )
    Skipped.new(reason: e.class.name.demodulize.underscore.to_sym)
  end

  # The cabinet that the update list gives for a code; nil when it gives none or entries disagree.
  def entry_cabinet_code(entries)
    codes = entries.filter_map { |entry| Integrations::Medelement::CabinetAttributes.code(entry) }.uniq
    codes.first if codes.one?
  end

  def update_marker(entry)
    return 'removed' if entry['REMOVED'].to_i == 1
    # Code-only and partial entries cannot prove that the current detail is unchanged.
    return unless (Integrations::Medelement::ReceptionChangeMarker::FIELDS - entry.keys).empty?
    return unless entry['PATIENT_CODE'].present? || entry['PROFILE_CODE'].present?

    Integrations::Medelement::ReceptionChangeMarker.call(entry)
  end

  def update_cursor!(cursor, started_at, complete)
    cursor.update!(
      value: complete ? started_at : cursor.value,
      last_poll_at: started_at,
      last_success_at: complete ? Time.current : cursor.last_success_at,
      current_interval_seconds: configuration.incremental_receptions_interval_seconds
    )
  end

  def log_poll(cursor, codes, counts)
    Rails.logger.info(
      "[MEDELEMENT::DELTA] hook=#{hook.id} changed_codes=#{codes.size} applied=#{counts[:applied]} " \
      "skipped=#{counts[:skipped]} complete=#{counts[:complete]} interval=#{cursor.current_interval_seconds} " \
      "cursor_age_seconds=#{cursor.value ? (Time.current - cursor.value).to_i : 'pending'}"
    )
  end

  def fetch_detail(code)
    snapshot_version = appointment_snapshot_version(code)
    detail = client.get_reception(reception_code: code, version: :v2)
    validate_detail!(detail, code)
    [detail, Integrations::Medelement::ReceptionChangeMarker.call(detail), snapshot_version]
  end

  def appointment_snapshot_version(code)
    prefix = Integrations::Medelement::AppointmentImporterService::RECEPTION_EXTERNAL_REF_PREFIX
    version = hook.account.scheduling_appointments.where(external_ref: "#{prefix}#{code}").pick(:updated_at)
    { exists: version.present?, updated_at: version }
  end

  def prioritize_unseen_changes(changes)
    return changes if changes.size <= 1

    seen_codes = Integrations::Medelement::DeltaSeenReception
                 .where(hook_id: hook.id, reception_code: changes.keys)
                 .distinct
                 .pluck(:reception_code)
                 .to_set
    return changes if seen_codes.empty? || seen_codes.size == changes.size

    unseen, previously_seen = changes.partition { |code, _entries| seen_codes.exclude?(code) }
    (unseen + previously_seen).to_h
  end

  def seen?(code, marker)
    Integrations::Medelement::DeltaSeenReception.exists?(hook_id: hook.id, reception_code: code, change_marker: marker)
  end

  def mark_seen!(code, marker)
    Integrations::Medelement::DeltaSeenReception.create_or_find_by!(
      hook: hook, reception_code: code, change_marker: marker
    ) { |seen| seen.processed_at = Time.current }
  end

  def find_cursor
    Integrations::Medelement::SyncCursor.find_or_create_by!(hook: hook, name: CURSOR_NAME)
  end

  def reception_code!(entry)
    code = entry.is_a?(Hash) && (entry['RECEPTION_CODE'] || entry['receptionCode'] || entry['reception_code'])
    raise Integrations::Medelement::Client::ApiError, 'Medelement delta entry has no reception code' if code.blank?

    code.to_s
  end
end
