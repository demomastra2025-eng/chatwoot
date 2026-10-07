class Integrations::Medelement::ReceptionsDeltaService
  OVERLAP = 3.minutes
  MAX_CHANGED = 200
  CURSOR_NAME = 'receptions_delta'.freeze

  def initialize(hook:, client: nil, configuration: nil, renew_locks: nil)
    @hook = hook
    @configuration = configuration || Integrations::Medelement::Configuration.new(hook: hook)
    @client = client || Integrations::Medelement::Client.new(configuration: @configuration)
    @renew_locks = renew_locks
  end

  def perform
    return :disabled unless enabled?

    started_at = Time.current
    cursor = find_cursor
    codes = changed_codes(cursor, started_at)
    counts = apply_codes(codes)
    complete = counts[:complete]
    update_cursor!(cursor, started_at, complete)
    Integrations::Medelement::DeltaMissAudit.new(hook: hook).resolve_candidates!(poll_completed_at: Time.current) if complete
    log_poll(cursor, codes, counts)
    counts.merge(changed_codes: codes.size)
  end

  private

  attr_reader :hook, :client, :configuration

  def enabled?
    hook.enabled? && hook.feature_allowed? && configuration.sync_receptions? &&
      configuration.incremental_receptions_enabled?
  end

  def changed_codes(cursor, started_at)
    from = (cursor.value || started_at) - OVERLAP
    entries = client.receptions_by_update_date(
      update_date_from: from.in_time_zone(configuration.time_zone).strftime('%d.%m.%Y %H:%M')
    )
    entries.map { |entry| reception_code!(entry) }.uniq.sort
  end

  def apply_codes(codes)
    applied = 0
    skipped = 0
    processed = 0
    complete = true
    codes.each do |code|
      outcome = process_code(code, processed)
      if outcome == :seen
        skipped += 1
        next
      end
      if outcome == :cap
        complete = false
        break
      end

      outcome == :out_of_scope ? skipped += 1 : applied += 1
      processed += 1
    end

    { applied: applied, skipped: skipped, complete: complete }
  end

  def process_code(code, processed)
    @renew_locks&.call
    detail, marker = fetch_detail(code)
    return :seen if seen?(code, marker)
    return :cap if processed >= MAX_CHANGED

    result = apply_detail!(detail)
    mark_seen!(code, marker)
    result
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
    detail = client.get_reception(reception_code: code, version: :v2)
    validate_detail!(detail, code)
    [detail, Integrations::Medelement::ReceptionChangeMarker.call(detail)]
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

  def validate_detail!(detail, code)
    valid = detail.is_a?(Hash) && detail['RECEPTION_CODE'].to_s == code &&
            (detail['REMOVED'].to_i == 1 || (detail['SERVICES'].is_a?(Array) &&
              (detail['PROFILE_CODE'].presence || detail['PATIENT_CODE'].presence)))
    raise Integrations::Medelement::Client::ApiError, 'Medelement delta reception detail is incomplete' unless valid

    Integrations::Medelement::ProviderScope.validate_write!(detail, organization_id: configuration.organization_id)
  end

  def apply_detail!(detail)
    Integrations::Medelement::ReceptionsSyncService.new(
      account: hook.account, client: client, configuration: configuration
    ).import_reported_reception!(detail)
  rescue Integrations::Medelement::ReceptionsSyncService::OutOfScopeReception
    :out_of_scope
  end
end
