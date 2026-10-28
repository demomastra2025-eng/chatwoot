# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ReceptionsSyncService
  InvalidReceptionError = Class.new(StandardError)
  # The reason is one of OUT_OF_SCOPE_REASONS, so that a dry run can say why a reception was refused.
  OutOfScopeReception = Class.new(StandardError) do
    attr_reader :reason

    def initialize(message = nil, reason: nil)
      super(message)
      @reason = reason
    end
  end
  OutOfScope = Data.define(:reason)
  OUT_OF_SCOPE_REASONS = %i[specialist_not_mapped cabinet_unknown cabinet_mismatch].freeze
  IncompleteSnapshotError = Class.new(StandardError)
  MAX_RECEPTIONS_PER_REQUEST = 1000
  LIST_FINGERPRINT_KEY = 'medelement_list_fingerprint'.freeze
  DETAIL_SYNCED_AT_KEY = 'medelement_detail_synced_at'.freeze
  DETAIL_RETRY_AT_KEY = 'medelement_detail_retry_at'.freeze
  AUDIT_METADATA_KEYS = [LIST_FINGERPRINT_KEY, DETAIL_SYNCED_AT_KEY, DETAIL_RETRY_AT_KEY, 'provider_status_audit'].freeze
  DETAIL_STATE_KEY = '_MEDELEMENT_DETAIL_STATE'.freeze
  DETAIL_RETRY_INTERVAL = 15.minutes
  REALTIME_DAYS_BACK = 1
  REALTIME_DAYS_FORWARD = 14
  WINDOW_MODES = %i[full realtime].freeze
  LIST_FINGERPRINT_FIELDS = %w[
    RECEPTION_CODE PATIENT_CODE STARTTIME ENDTIME ACTIVE REMOVED PAID NOTIFY MARKER_CODE
    SPECIALIST_CODE COMPANY_CABINET_CODE specialistCode
  ].freeze
  PROVIDER_BINDING_GRACE_PERIOD = Integrations::Medelement::SpecialistsSyncService::MISSING_GRACE_PERIOD
  PROVIDER_LAST_SEEN_AT_KEY = Integrations::Medelement::SpecialistsSyncService::LAST_SEEN_AT_KEY

  def initialize(account:, client:, configuration:, **options)
    @account = account
    @client = client
    @configuration = configuration
    @conflict_tracker = options[:conflict_tracker]
    @hook = options[:hook]
    @sync_run = options[:sync_run]
    @window_mode = options.fetch(:window_mode, :full).to_sym
    @authoritative_specialist_codes = options[:authoritative_specialist_codes]
    raise ArgumentError, "Unsupported Medelement receptions window mode: #{@window_mode}" unless @window_mode.in?(WINDOW_MODES)

    @importer = Integrations::Medelement::AppointmentImporterService.new(
      account: account,
      conflict_tracker: @conflict_tracker
    )
  end

  def perform
    @complete_resource_ids = Set.new
    @appointment_snapshot_versions = load_appointment_snapshot_versions
    resource_map = medelement_resource_map
    snapshot = build_snapshot(resource_map)
    contacts_by_patient_code = synced_contacts(snapshot)
    sync_result = sync_snapshot(snapshot, resource_map, contacts_by_patient_code)
    cleanup_missing_appointments!(sync_result[:desired_external_refs]) if @complete_resource_ids.any?
    finalize_sync_result(sync_result)
  end

  # A reported delta code does not authorize absence reconciliation for any other reception. The single-reception detail has
  # no cabinet (the list has), so a cabinet that the update list reported for the code can be passed in; it is used only for a
  # reception that is new to OneLink.
  def import_reported_reception!(detail, entry_cabinet_code: nil)
    code = detail.fetch('RECEPTION_CODE').to_s
    external_ref = importer.external_ref_for(code)
    appointment = account.scheduling_appointments.find_by(external_ref: external_ref)
    return reconcile_reported_removal(appointment) if detail['REMOVED'].to_i == 1

    resource, cabinet_code = delta_scope!(detail, appointment, entry_cabinet_code)
    reception = delta_reception(detail, cabinet_code)
    @appointment_snapshot_versions = { external_ref => appointment&.updated_at }.compact
    contacts = synced_contacts([reception.merge(DETAIL_STATE_KEY => 'fetched')])
    sync_reception(reception, resource, contacts)
  end

  # The status apply_reported_status! would give the appointment of this reception, from the importer's own status mapping
  # and without saving anything. :absent when OneLink has no such appointment.
  def preview_reported_status(detail)
    appointment = reported_appointment(detail)
    return :absent unless appointment
    return 'cancelled' if detail['REMOVED'].to_i == 1

    importer.provider_status_for(appointment, status_reception(detail), reported_starts_at(detail))
  end

  # Gives an appointment that OneLink already has the status the single-reception detail says, and nothing else of the detail:
  # no contact, client fields, services, times, resource, cabinet or payments (see AppointmentImporterService#apply_provider_status!).
  # The appointment is OneLink's already, so neither its specialist nor its cabinet is asked for. A removed reception takes the
  # way import_reported_reception! takes it. only_from: the statuses the appointment must still have when its row is locked.
  # Gives :absent when OneLink has no such appointment, and :no_longer_open when it has another status than only_from.
  def apply_reported_status!(detail, only_from: nil)
    appointment = reported_appointment(detail)
    return :absent unless appointment
    return reconcile_reported_removal(appointment) if detail['REMOVED'].to_i == 1

    importer.apply_provider_status!(appointment, status_reception(detail), starts_at: reported_starts_at(detail), only_from: only_from)
  end

  # Whether the specialist of the detail is one of OneLink's. Only worth reporting for an appointment OneLink already has:
  # applying its status does not depend on it.
  def specialist_mapped?(detail)
    @mapped_specialist_codes ||= medelement_resource_map.keys.to_set
    @mapped_specialist_codes.include?(reported_specialist_code(detail))
  end

  private

  attr_reader :account, :client, :configuration, :conflict_tracker, :importer, :appointment_snapshot_versions, :window_mode

  def reconcile_reported_removal(appointment)
    return :absent unless appointment

    Integrations::Medelement::MissingAppointmentReconciler.new(
      appointment: appointment, snapshot_version: appointment.updated_at, provider_removal_confirmed: true
    ).perform
  end

  # The resource of the specialist and the cabinet the reception is imported with. The cabinet of a reception never changes
  # once it is created, so a reception that OneLink already has keeps its stored cabinet, also when MedElement now gives it to
  # another specialist: nil here, and the cabinet is neither looked up, compared nor guessed.
  def delta_scope!(detail, appointment, entry_cabinet_code)
    resource = medelement_resource_map[reported_specialist_code(detail)]
    raise OutOfScopeReception.new('Medelement delta specialist is not mapped', reason: :specialist_not_mapped) unless resource
    return [resource, nil] if appointment

    [resource, new_reception_cabinet_code!(detail, resource, entry_cabinet_code)]
  end

  def reported_specialist_code(detail)
    (detail['SPECIALIST_CODE'] || detail['specialistCode']).to_s
  end

  def reported_appointment(detail)
    account.scheduling_appointments.find_by(external_ref: importer.external_ref_for(detail.fetch('RECEPTION_CODE').to_s))
  end

  # What the importer reads to give a status: the detail alone, and marked as such so that what it does not say stays.
  def status_reception(detail)
    detail.merge(Integrations::Medelement::AppointmentImporterService::DETAIL_ONLY_KEY => true)
  end

  def reported_starts_at(detail)
    parse_time(detail['STARTTIME'])
  rescue ArgumentError
    nil
  end

  # A reception that is new to OneLink needs a cabinet, and the v2 single-reception detail carries none. A cabinet that is
  # reported (by the detail, else by the update list) must be one of the specialist cabinets. Without one, the only cabinet of
  # the specialist is used; a specialist with several cabinets leaves the reception out of scope.
  def new_reception_cabinet_code!(detail, resource, entry_cabinet_code)
    mapped = mapped_cabinet_codes(resource)
    reported = detail['COMPANY_CABINET_CODE'].to_s.presence || entry_cabinet_code.to_s.presence
    return reported_cabinet_code!(reported, mapped) if reported
    return mapped.first if mapped.one?

    raise OutOfScopeReception.new('Medelement delta cabinet is unknown', reason: :cabinet_unknown)
  end

  def reported_cabinet_code!(reported, mapped)
    return reported if mapped.include?(reported)

    raise OutOfScopeReception.new('Medelement delta cabinet is not mapped', reason: :cabinet_mismatch)
  end

  def mapped_cabinet_codes(resource)
    Array(resource.custom_attributes['medelement_cabinets']).filter_map do |cabinet|
      Integrations::Medelement::CabinetAttributes.code(cabinet)&.to_s
    end.uniq
  end

  # cabinet_code nil: the appointment keeps its stored cabinet, whatever cabinet the detail names.
  def delta_reception(detail, cabinet_code)
    detail.except('COMPANY_CABINET_CODE').merge(
      'PATIENT_CODE' => detail['PATIENT_CODE'].presence || detail['PROFILE_CODE'],
      'specialistCode' => detail['SPECIALIST_CODE'] || detail['specialistCode'],
      '_MEDELEMENT_LIST_FINGERPRINT' => list_fingerprint(detail),
      '_MEDELEMENT_DETAIL_SYNCED_AT' => Time.current.iso8601,
      Integrations::Medelement::AppointmentImporterService::DETAIL_ONLY_KEY => true
    ).merge(cabinet_code.present? ? { 'COMPANY_CABINET_CODE' => cabinet_code } : {})
  end

  def load_appointment_snapshot_versions
    account.scheduling_appointments
           .where(
             'external_ref LIKE ?',
             "#{Integrations::Medelement::AppointmentImporterService::RECEPTION_EXTERNAL_REF_PREFIX}%"
           )
           .pluck(:external_ref, :updated_at)
           .to_h
  end

  def build_snapshot(resource_map)
    snapshot = resource_map.values.flat_map { |resource| snapshot_for_resource(resource) }

    listed_receptions = snapshot.uniq { |reception| reception['RECEPTION_CODE'].to_s }
    @appointments_by_external_ref = appointments_by_external_ref(listed_receptions)
    @detail_budget_remaining = configuration.reception_detail_budget

    sorted_receptions = listed_receptions.sort_by { |reception| detail_priority(reception) }
    prefetch_thread = start_patient_prefetch_pipeline(sorted_receptions)
    begin
      sorted_receptions.map { |reception| enrich_reception_if_needed(reception) }
    ensure
      prefetch_thread&.join
    end
  end

  def snapshot_for_resource(resource)
    specialist_code = resource.custom_attributes['medelement_specialist_code']
    cabinets = Array(resource.custom_attributes['medelement_cabinets'])
    rows = cabinets.map { |cabinet| snapshot_for_cabinet(cabinet, specialist_code) }
    authoritative = @authoritative_specialist_codes.nil? || @authoritative_specialist_codes.include?(specialist_code.to_s)
    @complete_resource_ids << resource.id if cabinets.present? && rows.none?(&:nil?) && authoritative
    rows.compact.flatten
  end

  def enrich_reception_if_needed(reception)
    fingerprint = list_fingerprint(reception)
    return reception.merge(DETAIL_STATE_KEY => 'removed') if reception['REMOVED'].to_i == 1

    appointment = appointments_by_external_ref_cache[external_ref_for(reception)]
    if detail_retry_deferred?(appointment, fingerprint)
      return reception.merge(DETAIL_STATE_KEY => 'retry_deferred', '_MEDELEMENT_LIST_FINGERPRINT' => fingerprint)
    end
    unless detail_required?(appointment, fingerprint)
      return reception.merge(DETAIL_STATE_KEY => 'fresh', '_MEDELEMENT_LIST_FINGERPRINT' => fingerprint)
    end

    return deferred_reception(reception, fingerprint) if detail_budget_remaining <= 0

    @detail_budget_remaining -= 1

    reception_code = reception['RECEPTION_CODE'].to_s
    detail = client.get_reception(reception_code: reception_code, version: :v2)
    validate_reception_detail!(detail, reception)

    enriched_reception(reception, detail, fingerprint)
  end

  def deferred_reception(reception, fingerprint)
    reception.merge(DETAIL_STATE_KEY => 'deferred', '_MEDELEMENT_LIST_FINGERPRINT' => fingerprint)
  end

  def enriched_reception(reception, detail, fingerprint)
    reception.merge(detail).merge(
      'PATIENT_CODE' => reception['PATIENT_CODE'].presence || detail['PROFILE_CODE'],
      DETAIL_STATE_KEY => 'fetched',
      '_MEDELEMENT_LIST_FINGERPRINT' => fingerprint,
      '_MEDELEMENT_DETAIL_SYNCED_AT' => Time.current.iso8601
    )
  end

  def appointments_by_external_ref(receptions)
    external_refs = receptions.map { |reception| external_ref_for(reception) }
    account.scheduling_appointments.where(external_ref: external_refs).index_by(&:external_ref)
  end

  def appointments_by_external_ref_cache
    @appointments_by_external_ref || {}
  end

  def detail_priority(reception)
    return 4 if reception['REMOVED'].to_i == 1

    fingerprint = list_fingerprint(reception)
    appointment = appointments_by_external_ref_cache[external_ref_for(reception)]
    return 0 unless appointment
    return 1 if appointment.custom_attributes[LIST_FINGERPRINT_KEY].to_s != fingerprint
    return 2 if detail_stale?(appointment)

    3
  end

  def detail_required?(appointment, fingerprint)
    return true unless appointment
    return true if appointment.custom_attributes[LIST_FINGERPRINT_KEY].to_s != fingerprint

    detail_stale?(appointment)
  end

  def detail_stale?(appointment)
    synced_at = Time.zone.parse(appointment.custom_attributes[DETAIL_SYNCED_AT_KEY].to_s)
    synced_at.blank? || synced_at < configuration.reception_detail_refresh_interval.ago
  rescue ArgumentError, TypeError
    true
  end

  def detail_retry_deferred?(appointment, fingerprint)
    return false unless appointment
    return false if appointment.custom_attributes[LIST_FINGERPRINT_KEY].to_s != fingerprint

    retry_at = Time.zone.parse(appointment.custom_attributes[DETAIL_RETRY_AT_KEY].to_s)
    retry_at.present? && retry_at > Time.current
  rescue ArgumentError, TypeError
    false
  end

  def list_fingerprint(reception)
    payload = reception.slice(*LIST_FINGERPRINT_FIELDS).transform_values(&:to_s)
    Digest::SHA256.hexdigest(payload.sort.to_h.to_json)
  end

  def detail_budget_remaining
    @detail_budget_remaining.to_i
  end

  def validate_reception_detail!(detail, listed_reception)
    valid = detail.is_a?(Hash) &&
            detail['RECEPTION_CODE'].to_s == listed_reception['RECEPTION_CODE'].to_s &&
            detail['SERVICES'].is_a?(Array) &&
            detail_patient_code(detail).present? &&
            detail_patient_code(detail) == listed_reception['PATIENT_CODE'].to_s
    raise IncompleteSnapshotError, "Medelement reception detail is incomplete for account=#{account.id}" unless valid

    Integrations::Medelement::ProviderScope.validate_write!(
      detail,
      organization_id: configuration.organization_id
    )
  rescue Integrations::Medelement::ProviderScope::MismatchError => e
    raise IncompleteSnapshotError, "Medelement reception detail scope is invalid for account=#{account.id}: #{e.message}"
  end

  def detail_patient_code(detail)
    (detail['PROFILE_CODE'] || detail['PATIENT_CODE']).to_s
  end

  def fetch_receptions_for_pair(specialist_code:, company_cabinet_code:, from:, to:)
    receptions = client.get_receptions(
      company_cabinet_code: company_cabinet_code,
      specialist_code: specialist_code,
      begin_datetime: from.in_time_zone(configuration.time_zone).strftime('%d.%m.%Y %H:%M:%S'),
      end_datetime: to.in_time_zone(configuration.time_zone).strftime('%d.%m.%Y %H:%M:%S')
    )

    return receptions if receptions.size < MAX_RECEPTIONS_PER_REQUEST

    raise IncompleteSnapshotError, "Medelement reception snapshot is saturated for account=#{account.id}" if (to - from) <= 1.day

    split_fetch_receptions_for_pair(
      specialist_code: specialist_code,
      company_cabinet_code: company_cabinet_code,
      from: from,
      to: to
    )
  end

  def provider_backed_appointments_in_window
    scope = account.scheduling_appointments.where(starts_at: range_start..range_end)
    imported = scope.where(source: 'medelement')
    trusted_outbound = scope
                       .where(id: succeeded_outbound_appointment_ids)
                       .where("custom_attributes ->> 'medelement_provider_sync_status' = 'succeeded'")
                       .where(
                         "external_ref = :prefix || (custom_attributes ->> 'medelement_reception_code')",
                         prefix: Integrations::Medelement::AppointmentImporterService::RECEPTION_EXTERNAL_REF_PREFIX
                       )

    imported.or(trusted_outbound)
  end

  def succeeded_outbound_appointment_ids
    Integrations::Medelement::ProviderCommand
      .where(account_id: account.id, operation: 'create_reception', status: 'succeeded')
      .select(:appointment_id)
  end

  def medelement_resources
    account.scheduling_resources.available_for_scheduling
           .where("custom_attributes ->> 'medelement_specialist_code' IS NOT NULL")
  end

  def parse_time(value)
    ActiveSupport::TimeZone[configuration.time_zone].parse(value.to_s)
  end

  def range_end
    @range_end ||= begin
      date = Time.current.in_time_zone(configuration.time_zone).to_date + range_days_forward + 1
      ActiveSupport::TimeZone[configuration.time_zone].local(date.year, date.month, date.day)
    end
  end

  def range_start
    @range_start ||= begin
      date = Time.current.in_time_zone(configuration.time_zone).to_date - range_days_back
      ActiveSupport::TimeZone[configuration.time_zone].local(date.year, date.month, date.day)
    end
  end

  def range_days_back
    return configuration.receptions_days_back if window_mode == :full

    [configuration.receptions_days_back, REALTIME_DAYS_BACK].min
  end

  def range_days_forward
    return configuration.receptions_days_forward if window_mode == :full

    [configuration.receptions_days_forward, REALTIME_DAYS_FORWARD].min
  end

  def window_metadata
    {
      window_mode: window_mode.to_s,
      window_start: range_start.iso8601,
      window_end: range_end.iso8601
    }
  end

  def cleanup_missing_appointments!(desired_external_refs)
    provider_backed_appointments_in_window.where(resource_id: @complete_resource_ids.to_a).find_each do |appointment|
      # A local-only cancellation still expects the reception in MedElement, so its disappearance is reconciled.
      next if appointment.status == 'cancelled' && !Integrations::Medelement::LocalCancellation.marked?(appointment)
      next if desired_external_refs.include?(appointment.external_ref)

      ApplicationRecord.transaction do
        previous_status = appointment.status
        Integrations::Medelement::MissingAppointmentReconciler.new(
          appointment: appointment,
          snapshot_version: appointment_snapshot_versions[appointment.external_ref]
        ).perform
        audit_removal!(appointment) if previous_status != 'cancelled' && appointment.status == 'cancelled'
      end
    end
  end

  def finalize_sync_result(sync_result)
    audit_full_sweep_result!
    sync_result[:skipped_pair_count] = skipped_pair_count
    sync_result.merge!(window_metadata)
    log_sync_summary(sync_result)
    sync_result.except(:desired_external_refs)
  end

  def audit_full_sweep_result!
    return unless @hook

    Integrations::Medelement::DeltaMissAudit.new(hook: @hook).record_full_sweep_result!
  rescue ActiveRecord::ActiveRecordError => e
    raise Integrations::Medelement::DeltaMissAudit::AuditUnavailableError, 'Medelement delta miss audit failed', cause: e
  end

  def audit_change!(appointment, reception)
    return unless @hook && appointment.previous_changes.present?

    changed_fields = audit_changed_fields(appointment.previous_changes)
    return if changed_fields.empty?

    Integrations::Medelement::DeltaMissAudit.new(hook: @hook).record_change!(
      reception_code: reception['RECEPTION_CODE'].to_s,
      change_marker: Integrations::Medelement::ReceptionChangeMarker.call(reception),
      kind: appointment.previous_changes.key?('id') ? 'created' : 'changed',
      changed_fields: changed_fields, full_sweep_run: @sync_run
    )
    Integrations::Medelement::ScheduleChangeTracker.new(hook: @hook).mark_reception!(reception)
  rescue ActiveRecord::ActiveRecordError => e
    raise Integrations::Medelement::DeltaMissAudit::AuditUnavailableError, 'Medelement delta miss audit failed', cause: e
  end

  def audit_changed_fields(changes)
    fields = changes.keys - %w[updated_at created_at custom_attributes]
    return fields unless changes.key?('custom_attributes')

    before, after = changes['custom_attributes'].map(&:to_h)
    keys = (before.keys | after.keys) - AUDIT_METADATA_KEYS
    fields + keys.reject { |key| before[key] == after[key] }.map { |key| "custom_attributes.#{key}" }
  end

  def audit_removal!(appointment)
    return unless @hook

    prefix = Integrations::Medelement::AppointmentImporterService::RECEPTION_EXTERNAL_REF_PREFIX
    code = appointment.external_ref.to_s.delete_prefix(prefix)
    Integrations::Medelement::DeltaMissAudit.new(hook: @hook).record_change!(
      reception_code: code, change_marker: 'removed', kind: 'removed',
      changed_fields: %w[status payment_status custom_attributes], full_sweep_run: @sync_run
    )
  end

  def medelement_resource_map
    medelement_resources.each_with_object({}) do |resource, result|
      if stale_provider_binding?(resource)
        skip_stale_provider_bindings!(resource)
        next
      end

      result[resource.custom_attributes['medelement_specialist_code'].to_s] = resource
    end
  end

  def reception_patient_codes(snapshot)
    snapshot.filter_map do |item|
      item['PATIENT_CODE'].to_s if item[DETAIL_STATE_KEY] == 'fetched' && item['REMOVED'].to_i != 1
    end
  end

  def skipped_reception?(reception, resource)
    reception['REMOVED'].to_i == 1 || resource.blank?
  end

  def snapshot_for_cabinet(cabinet, specialist_code)
    company_cabinet_code = Integrations::Medelement::CabinetAttributes.code(cabinet)
    return nil if specialist_code.blank? || company_cabinet_code.blank?

    fetch_receptions_for_pair(
      specialist_code: specialist_code,
      company_cabinet_code: company_cabinet_code,
      from: range_start,
      to: range_end
    ).map do |reception|
      reception.merge(
        'specialistCode' => specialist_code,
        'COMPANY_CABINET_CODE' => reception['COMPANY_CABINET_CODE'].presence || company_cabinet_code
      )
    end
  end

  def stale_provider_binding?(resource)
    value = resource.custom_attributes[PROVIDER_LAST_SEEN_AT_KEY].to_s
    return false if value.blank?

    last_seen_at = Time.iso8601(value)
    last_seen_at < Time.current - PROVIDER_BINDING_GRACE_PERIOD
  rescue ArgumentError
    true
  end

  def skip_stale_provider_bindings!(resource)
    specialist_code = resource.custom_attributes['medelement_specialist_code']
    Array(resource.custom_attributes['medelement_cabinets']).each do |cabinet|
      skip_stale_provider_binding!(resource, specialist_code, cabinet)
    end
  end

  def skip_stale_provider_binding!(resource, specialist_code, cabinet)
    @skipped_pair_count = skipped_pair_count + 1
    entity_key = [specialist_code, Integrations::Medelement::CabinetAttributes.code(cabinet)].join(':')
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'specialist_cabinet',
      conflict_type: 'stale_provider_binding',
      entity_key: entity_key,
      severity: 'error',
      details: stale_provider_binding_details(resource, specialist_code, cabinet)
    )
    Rails.logger.warn(
      "[MEDELEMENT::RECEPTIONS_SYNC] Skipping stale provider binding for account=#{account.id} " \
      "resource_id=#{resource.id} entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(entity_key)}"
    )
  end

  def stale_provider_binding_details(resource, specialist_code, cabinet)
    {
      reason: 'Specialist/cabinet binding was not observed within the provider grace period',
      resource_id: resource.id,
      specialist_code: specialist_code,
      company_cabinet_code: Integrations::Medelement::CabinetAttributes.code(cabinet),
      provider_last_seen_at: resource.custom_attributes[PROVIDER_LAST_SEEN_AT_KEY]
    }
  end

  def skipped_pair_count
    @skipped_pair_count.to_i
  end

  def split_fetch_receptions_for_pair(specialist_code:, company_cabinet_code:, from:, to:)
    midpoint = from + ((to - from) / 2)
    receptions = fetch_receptions_for_pair(
      specialist_code: specialist_code,
      company_cabinet_code: company_cabinet_code,
      from: from,
      to: midpoint
    )
    receptions += fetch_receptions_for_pair(
      specialist_code: specialist_code,
      company_cabinet_code: company_cabinet_code,
      from: midpoint,
      to: to
    )
    receptions.uniq { |reception| reception['RECEPTION_CODE'].to_s }
  end

  def sync_reception(reception, resource, contacts_by_patient_code)
    import_context = import_context_for(reception)

    importer.upsert!(
      resource: resource,
      contact: contacts_by_patient_code[reception['PATIENT_CODE'].to_s],
      reception: reception,
      import_context: import_context
    )
  end

  def sync_snapshot(snapshot, resource_map, contacts_by_patient_code)
    snapshot.each_with_object(
      {
        desired_external_refs: Set.new,
        imported_count: 0,
        skipped_count: 0,
        detail_skipped_count: 0,
        detail_deferred_count: 0,
        detail_retry_deferred_count: 0
      }
    ) do |reception, result|
      resource = resource_map[reception['specialistCode'].to_s]
      next if skipped_reception?(reception, resource)

      result[:desired_external_refs] << external_ref_for(reception)
      sync_snapshot_reception(reception, resource, contacts_by_patient_code, result)
    end
  end

  def sync_snapshot_reception(reception, resource, contacts_by_patient_code, result)
    if reception[DETAIL_STATE_KEY] != 'fetched'
      preserve_unprocessed_reception_conflict!(reception)
      result[detail_state_counter(reception[DETAIL_STATE_KEY])] += 1
      return
    end

    ApplicationRecord.transaction do
      appointment = sync_reception(reception, resource, contacts_by_patient_code)
      audit_change!(appointment, reception)
    end
    result[:imported_count] += 1
  rescue Integrations::Medelement::AppointmentSnapshotGuard::StaleSnapshotError => e
    result[:skipped_count] += 1
    preserve_unprocessed_reception_conflict!(reception)
    log_stale_snapshot(reception, resource, e)
  rescue InvalidReceptionError, Integrations::Medelement::ReceptionServiceRows::InvalidSnapshotError,
         ActiveRecord::RecordInvalid, Scheduling::Error => e
    result[:skipped_count] += 1
    log_skipped_reception(reception, resource, e)
    defer_detail_retry!(reception)
  end

  def detail_state_counter(state)
    return :detail_deferred_count if state == 'deferred'
    return :detail_retry_deferred_count if state == 'retry_deferred'

    :detail_skipped_count
  end

  def defer_detail_retry!(reception)
    appointment = appointments_by_external_ref_cache[external_ref_for(reception)]
    return unless appointment

    appointment.with_lock do
      appointment.reload
      attributes = appointment.custom_attributes.merge(
        LIST_FINGERPRINT_KEY => reception['_MEDELEMENT_LIST_FINGERPRINT'],
        DETAIL_RETRY_AT_KEY => DETAIL_RETRY_INTERVAL.from_now.iso8601
      )
      # The rejection may be caused by an existing invalid association, so persist only isolated reconciliation metadata.
      # rubocop:disable Rails/SkipsModelValidations
      appointment.update_column(:custom_attributes, attributes)
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def external_ref_for(reception)
    importer.external_ref_for(reception['RECEPTION_CODE'].to_s)
  end

  def import_context_for(reception)
    starts_at = parse_time(reception['STARTTIME'])
    ends_at = parse_time(reception['ENDTIME'])
    external_ref = external_ref_for(reception)

    validate_import_context!(reception, starts_at, ends_at)

    {
      starts_at: starts_at,
      ends_at: ends_at,
      source_timezone: configuration.time_zone,
      specialist_code: reception['specialistCode'],
      snapshot_version: {
        exists: appointment_snapshot_versions.key?(external_ref),
        updated_at: appointment_snapshot_versions[external_ref]
      },
      list_fingerprint: reception['_MEDELEMENT_LIST_FINGERPRINT'],
      detail_synced_at: reception['_MEDELEMENT_DETAIL_SYNCED_AT']
    }
  end

  def log_stale_snapshot(reception, resource, error)
    entity_key = reception_entity_key(reception)
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'reception',
      conflict_type: 'stale_snapshot',
      entity_key: entity_key,
      severity: 'warning',
      details: reception_conflict_details(reception, resource, error)
    )
    Rails.logger.warn(
      "[MEDELEMENT::RECEPTIONS_SYNC] Skipping stale reception snapshot for account=#{account.id} " \
      "resource_id=#{resource.id} entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(entity_key)}"
    )
  end

  def log_skipped_reception(reception, resource, error)
    entity_key = reception_entity_key(reception)
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'reception',
      conflict_type: 'invalid_reception',
      entity_key: entity_key,
      severity: 'error',
      details: reception_conflict_details(reception, resource, error)
    )
    Rails.logger.warn(
      "[MEDELEMENT::RECEPTIONS_SYNC] Skipping reception for account=#{account.id} " \
      "resource_id=#{resource.id} entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(entity_key)} " \
      "reason=#{error.class}"
    )
  end

  def preserve_unprocessed_reception_conflict!(reception)
    return unless conflict_tracker

    conflict_tracker.preserve_open_conflict!(
      phase: 'receptions',
      entity_type: 'reception',
      conflict_type: 'invalid_reception',
      entity_key: reception_entity_key(reception)
    )
  end

  def reception_entity_key(reception)
    reception['RECEPTION_CODE'].presence || [reception['specialistCode'], reception['STARTTIME']].join(':')
  end

  def reception_time_epoch(value)
    parse_time(value)&.to_i
  rescue ArgumentError
    nil
  end

  def reception_conflict_details(reception, resource, error)
    {
      reason: error.message,
      reception_code: reception['RECEPTION_CODE'].presence,
      resource_id: resource.id,
      specialist_code: reception['specialistCode'].presence,
      patient_code: reception['PATIENT_CODE'].presence,
      starts_at_unix: reception_time_epoch(reception['STARTTIME']),
      ends_at_unix: reception_time_epoch(reception['ENDTIME'])
    }.compact
  end

  def log_sync_summary(sync_result)
    return if sync_result[:skipped_count].zero? && sync_result[:skipped_pair_count].zero?

    Rails.logger.warn(
      "[MEDELEMENT::RECEPTIONS_SYNC] Completed with skipped receptions for account=#{account.id} " \
      "imported=#{sync_result[:imported_count]} skipped=#{sync_result[:skipped_count]} " \
      "skipped_pairs=#{sync_result[:skipped_pair_count]}"
    )
  end

  def validate_import_context!(reception, starts_at, ends_at)
    reception_code = reception['RECEPTION_CODE'].to_s

    raise InvalidReceptionError, 'missing reception code' if reception_code.blank?
    raise InvalidReceptionError, 'missing start time' if starts_at.blank?
    raise InvalidReceptionError, 'missing end time' if ends_at.blank?
    return if ends_at > starts_at

    raise InvalidReceptionError, "invalid time range #{reception['STARTTIME']}..#{reception['ENDTIME']}"
  end

  def start_patient_prefetch_pipeline(sorted_receptions)
    @prefetched_patients = Concurrent::Map.new
    @preloaded_contacts = nil
    return nil unless configuration.sync_patients?

    candidate_codes = prefetch_candidate_patient_codes(sorted_receptions)
    return nil if candidate_codes.empty?

    patients_service = build_patients_sync_service
    @preloaded_contacts = patients_service.preload_contacts_by_patient_code(candidate_codes)
    stale_codes = patients_service.stale_patient_codes(candidate_codes, @preloaded_contacts)
    return nil if stale_codes.empty?

    Thread.new(stale_codes, @prefetched_patients) do |codes, map|
      codes.each do |patient_code|
        map[patient_code] = client.get_patient(patient_code: patient_code)
      rescue StandardError
        # Fallback to synchronous fetch on main thread so error handling & conflict tracking stay deterministic.
        next
      end
    ensure
      ActiveRecord::Base.connection_pool.release_connection if ActiveRecord::Base.connection_pool.active_connection?
    end
  end

  def prefetch_candidate_patient_codes(sorted_receptions)
    sorted_receptions.filter_map do |item|
      item['PATIENT_CODE'].to_s.presence if item['REMOVED'].to_i != 1
    end.uniq
  end

  def build_patients_sync_service
    Integrations::Medelement::PatientsSyncService.new(
      account: account,
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: configuration.organization_id
    )
  end

  def synced_contacts(snapshot)
    return {} unless configuration.sync_patients?

    prefetched = {}
    @prefetched_patients&.each_pair { |k, v| prefetched[k] = v }
    build_patients_sync_service.sync_patient_codes(
      reception_patient_codes(snapshot),
      prefetched_patients: prefetched,
      preloaded_contacts: @preloaded_contacts
    )
  end
end
# rubocop:enable Metrics/ClassLength
