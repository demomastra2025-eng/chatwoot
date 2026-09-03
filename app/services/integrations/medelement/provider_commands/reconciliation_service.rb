# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
class Integrations::Medelement::ProviderCommands::ReconciliationService
  PHASE_HANDLERS = {
    'patient_create' => :reconcile_patient_create,
    'patient_update' => :reconcile_patient_update,
    'reception_create' => :reconcile_reception_create,
    'reception_move' => :reconcile_reception_move,
    'reception_remove' => :reconcile_reception_remove
  }.freeze

  def initialize(command:, client: nil)
    @command = command
    @client = client
  end

  def perform
    return unless command.reconcilable?
    return unless valid_for_reconciliation?

    @reconciliation_claim_token = lifecycle.claim_attempt!
    return if reconciliation_claim_token.blank?

    reconcile_write!
  rescue Integrations::Medelement::Client::ApiError => e
    if reconciliation_claim_token.present?
      lifecycle.retry_unresolved!(
        'reconciliation_provider_error', status: e.status, claim_token: reconciliation_claim_token
      )
    end
  rescue Integrations::Medelement::ProviderScope::MismatchError
    lifecycle.defer_unknown!('provider_scope_mismatch', claim_token: reconciliation_claim_token) if reconciliation_claim_token.present?
  rescue StandardError => e
    Rails.logger.warn("[MEDELEMENT::RECONCILIATION] command_id=#{command.id} error=#{e.class}")
    lifecycle.retry_unresolved!('reconciliation_internal_error', claim_token: reconciliation_claim_token) if reconciliation_claim_token.present?
  end

  private

  attr_reader :command, :configuration, :reconciliation_claim_token

  def client
    @client ||= Integrations::Medelement::Client.new(configuration: configuration)
  end

  def reconcile_write!
    initialize_provider!
    handler = PHASE_HANDLERS[write_phase]
    return lifecycle.defer_unknown!('reconciliation_unknown_write_phase', claim_token: reconciliation_claim_token) if handler.blank?

    send(handler)
    lifecycle.retry_unresolved!('reconciliation_no_match', claim_token: reconciliation_claim_token)
  end

  def valid_for_reconciliation?
    return true if command.confirmation_matches_request_snapshot? && command.request_snapshot_valid?

    error_code = if command.confirmation_matches_request_snapshot?
                   'reconciliation_invalid_request_snapshot'
                 else
                   'reconciliation_invalid_confirmation'
                 end
    lifecycle.defer_unknown!(error_code)
    false
  end

  def lifecycle
    @lifecycle ||= Integrations::Medelement::ProviderCommands::ReconciliationLifecycle.new(command: command)
  end

  def write_phase
    command.execution_state.to_h['write_phase']
  end

  def reconcile_patient_create
    code = Integrations::Medelement::ProviderCommands::PatientResolver.new(
      command: command,
      client: client,
      organization_id: configuration.organization_id
    ).resolve_existing
    return if code.blank?
    return if conflicting_contact_patient_code?(code)

    if command.create_reception?
      applied = success_applier.patient_resolved_for_reception!(patient_code: code)
      Integrations::Medelement::ProviderCommandJob.perform_later(command.id) if applied
    else
      success_applier.patient!(patient_code: code)
    end
  end

  def conflicting_contact_patient_code?(patient_code)
    current_code = command.contact&.custom_attributes&.dig('medelement_patient_code').presence
    current_code.present? && current_code.to_s != patient_code.to_s
  end

  def reconcile_patient_update
    matches = client.search_patients_by_phone(phone_number: patient_snapshot.fetch('phone_number'))
    patient = matches.find { |record| record['PROFILE_CODE'].to_s == provider_patient_code.to_s }
    return if patient.blank?

    Integrations::Medelement::ProviderScope.validate_patient!(
      patient,
      organization_id: configuration.organization_id,
      expected_patient_code: provider_patient_code,
      expected_iin: patient_snapshot.dig('payload', 'iin'),
      expected_phone_numbers: [patient_snapshot.fetch('phone_number')]
    )
    return unless patient_snapshot_matches?(patient)

    success_applier.patient!(patient_code: provider_patient_code)
  end

  def reconcile_reception_create
    return if reconcile_known_created_reception

    candidates = destination_receptions.reject do |reception|
      preflight_reception_codes.include?(reception['RECEPTION_CODE'].to_s) ||
        !reception_verifier.destination_match?(reception)
    end
    return unless candidates.one?

    reception = candidates.first
    reception_code = reception['RECEPTION_CODE'].to_s
    return if reception_code.blank?

    patient_code = reception['PATIENT_CODE'].presence || reception['PROFILE_CODE'].presence
    success_applier.reception_created!(reception_code: reception_code, patient_code: patient_code)
  end

  def reconcile_known_created_reception
    reception_code = written_reception_code
    return false if reception_code.blank?

    detail = client.get_reception(reception_code: reception_code, version: :v2)
    reception = reconciled_created_reception(detail, reception_code)
    return false unless reception_verifier.destination_match?(reception, expected_reception_code: reception_code)

    patient_code = reception['PATIENT_CODE'].presence || reception['PROFILE_CODE'].presence
    success_applier.reception_created!(reception_code: reception_code, patient_code: patient_code)
    true
  rescue Integrations::Medelement::Client::ApiError
    false
  end

  def reconciled_created_reception(detail, reception_code)
    return detail if reception_verifier.destination_match?(detail, expected_reception_code: reception_code)

    merged_scoped_reception(detail, destination_receptions, reception_code)
  end

  def reconcile_reception_move
    detail = client.get_reception(reception_code: provider_reception_code)
    return success_applier.reception_moved! if reception_verifier.moved_match?(detail)
    return if reception_verifier.cabinet_matches?(detail)

    reception = merged_scoped_reception(detail, destination_receptions, provider_reception_code)
    return unless reception_verifier.moved_match?(reception)

    success_applier.reception_moved!
  end

  def reconcile_reception_remove
    detail = client.get_reception(reception_code: provider_reception_code, version: :v1)
    reception = completed_removed_identity(detail)
    success_applier.reception_removed! if reception_verifier.removed_match?(reception)
  end

  def completed_removed_identity(reception)
    return reception unless reception['REMOVED'].to_i == 1
    return reception unless reception_verifier.reference_matches?(reception)
    return reception unless reception_verifier.patient_matches?(reception)
    return reception unless reception_verifier.source_time_matches?(reception)

    reception.merge(
      'SPECIALIST_CODE' => specialist_code,
      'COMPANY_CABINET_CODE' => command.request_snapshot.fetch('company_cabinet_code')
    )
  end

  def merged_scoped_reception(detail, receptions, reception_code)
    scoped = receptions.find do |candidate|
      reception_verifier.reference_matches?(candidate, expected_code: reception_code)
    end
    scoped&.merge(detail) || detail
  end

  def destination_receptions
    range = destination_calendar_range
    client.get_receptions(
      company_cabinet_code: command.request_snapshot.fetch('company_cabinet_code'),
      specialist_code: specialist_code,
      begin_datetime: provider_datetime(range.begin),
      end_datetime: provider_datetime(range.end)
    )
  end

  def source_receptions
    range = source_calendar_range
    client.get_receptions(
      company_cabinet_code: command.request_snapshot.fetch('company_cabinet_code'),
      specialist_code: specialist_code,
      begin_datetime: provider_datetime(range.begin),
      end_datetime: provider_datetime(range.end)
    )
  end

  def destination_calendar_range
    calendar_range('destination')
  end

  def source_calendar_range
    calendar_range('source')
  end

  def calendar_range(prefix)
    zone = ActiveSupport::TimeZone[reception_snapshot.fetch('time_zone')]
    starts_on = snapshot_time("#{prefix}_starts_at").in_time_zone(zone).to_date
    ends_on = snapshot_time("#{prefix}_ends_at").in_time_zone(zone).to_date
    exclusive_end = ends_on + 1.day

    Range.new(
      zone.local(starts_on.year, starts_on.month, starts_on.day),
      zone.local(exclusive_end.year, exclusive_end.month, exclusive_end.day),
      true
    )
  end

  def preflight_reception_codes
    Array(command.execution_state.to_h['preflight_reception_codes']).map(&:to_s)
  end

  def patient_snapshot_matches?(patient)
    return false unless patient['REMOVED'].to_i.zero?

    desired = patient_snapshot.fetch('payload')
    fields_match = {
      'name' => 'NAME',
      'lastname' => 'LASTNAME',
      'middlename' => 'MIDDLENAME',
      'patient_email' => 'PATIENT_EMAIL',
      'birthday' => 'BIRTHDAY',
      'gender' => 'GENDER',
      'iin' => 'IIN'
    }.all? do |local_key, remote_key|
      desired[local_key].blank? || desired[local_key].to_s == patient[remote_key].to_s
    end

    fields_match && Integrations::Medelement::PhoneNumber.new(patient_snapshot.fetch('phone_number')).matches_patient?(patient)
  end

  def specialist_code
    reception_snapshot.fetch('specialist_code')
  end

  def provider_patient_code
    command.execution_state.to_h['write_provider_patient_code'].presence ||
      command.request_snapshot['provider_patient_code'].presence || command.provider_patient_code
  end

  def reception_verifier
    @reception_verifier ||= Integrations::Medelement::ProviderCommands::ReceptionVerifier.new(
      command: command,
      provider_patient_code: provider_patient_code
    )
  end

  def provider_reception_code
    command.request_snapshot['provider_reception_code'].to_s
  end

  def written_reception_code
    command.execution_state.to_h['write_provider_reception_code'].presence || command.provider_reception_code
  end

  def patient_snapshot
    @patient_snapshot ||= command.request_snapshot.fetch('patient')
  end

  def reception_snapshot
    @reception_snapshot ||= command.request_snapshot.fetch('reception')
  end

  def snapshot_time(key)
    Time.iso8601(reception_snapshot.fetch(key))
  end

  def provider_datetime(value)
    value.in_time_zone(reception_snapshot.fetch('time_zone')).strftime('%d.%m.%Y %H:%M:%S')
  end

  def success_applier
    @success_applier ||= Integrations::Medelement::ProviderCommands::SuccessApplier.new(
      command: command,
      reconciliation_claim_token: reconciliation_claim_token
    )
  end

  def initialize_provider!
    @configuration = Integrations::Medelement::Configuration.new(hook: command.hook)
    client
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
