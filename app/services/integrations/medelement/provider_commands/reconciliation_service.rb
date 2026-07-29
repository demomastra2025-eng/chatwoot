class Integrations::Medelement::ProviderCommands::ReconciliationService
  PHASE_HANDLERS = {
    'patient_create' => :reconcile_patient_create,
    'patient_update' => :reconcile_patient_update,
    'reception_create' => :reconcile_reception_create,
    'reception_move' => :reconcile_reception_move,
    'reception_remove' => :reconcile_reception_remove
  }.freeze

  def initialize(command:)
    @command = command
  end

  def perform
    return unless command.reconciliation_required?
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
  rescue StandardError => e
    Rails.logger.warn("[MEDELEMENT::RECONCILIATION] command_id=#{command.id} error=#{e.class}")
    lifecycle.retry_unresolved!('reconciliation_internal_error', claim_token: reconciliation_claim_token) if reconciliation_claim_token.present?
  end

  private

  attr_reader :command, :configuration, :client, :reconciliation_claim_token

  def reconcile_write!
    initialize_provider!
    handler = PHASE_HANDLERS[write_phase]
    return lifecycle.fail!('reconciliation_unknown_write_phase', claim_token: reconciliation_claim_token) if handler.blank?

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
    lifecycle.fail!(error_code)
    false
  end

  def lifecycle
    @lifecycle ||= Integrations::Medelement::ProviderCommands::ReconciliationLifecycle.new(command: command)
  end

  def write_phase
    command.execution_state.to_h['write_phase']
  end

  def reconcile_patient_create
    code = Integrations::Medelement::ProviderCommands::PatientResolver.new(command: command, client: client).resolve_existing
    return if code.blank?

    if command.create_reception?
      applied = success_applier.patient_resolved_for_reception!(patient_code: code)
      Integrations::Medelement::ProviderCommandJob.perform_later(command.id) if applied
    else
      success_applier.patient!(patient_code: code)
    end
  end

  def reconcile_patient_update
    matches = client.search_patients_by_phone(phone_number: patient_snapshot.fetch('phone_number'))
    patient = matches.find { |record| record['PROFILE_CODE'].to_s == provider_patient_code.to_s }
    return unless patient.present? && patient_snapshot_matches?(patient)

    success_applier.patient!(patient_code: provider_patient_code)
  end

  def reconcile_reception_create
    candidates = destination_receptions.reject do |reception|
      preflight_reception_codes.include?(reception['RECEPTION_CODE'].to_s) || !exact_destination_match?(reception)
    end
    return unless candidates.one?

    reception = candidates.first
    reception_code = reception['RECEPTION_CODE'].to_s
    return if reception_code.blank?

    patient_code = reception['PATIENT_CODE'].presence || reception['PROFILE_CODE'].presence
    success_applier.reception_created!(reception_code: reception_code, patient_code: patient_code)
  end

  def reconcile_reception_move
    reception = client.get_reception(reception_code: provider_reception_code)
    return unless remote_reception_identity_matches?(reception)
    return unless remote_time(reception['STARTTIME'])&.to_i == snapshot_time('destination_starts_at').to_i
    return unless remote_time(reception['ENDTIME'])&.to_i == snapshot_time('destination_ends_at').to_i

    success_applier.reception_moved!
  end

  def remote_reception_identity_matches?(reception)
    patient_code = reception['PROFILE_CODE'].presence || reception['PATIENT_CODE'].presence

    reception.key?('REMOVED') && reception['REMOVED'].to_i.zero? &&
      patient_code.present? && reception['SPECIALIST_CODE'].present? &&
      patient_code.to_s == provider_patient_code.to_s &&
      reception['SPECIALIST_CODE'].to_s == specialist_code.to_s
  end

  def reconcile_reception_remove
    reception = client.get_reception(reception_code: provider_reception_code)
    success_applier.reception_removed! if reception['REMOVED'].to_i == 1
  end

  def destination_receptions
    client.get_receptions(
      company_cabinet_code: command.request_snapshot.fetch('company_cabinet_code'),
      specialist_code: specialist_code,
      begin_datetime: provider_datetime(snapshot_time('destination_starts_at')),
      end_datetime: provider_datetime(snapshot_time('destination_ends_at'))
    )
  end

  def exact_destination_match?(reception)
    active_reception?(reception) && reception_patient_matches?(reception) && reception_time_matches?(reception)
  end

  def active_reception?(reception)
    reception.key?('REMOVED') && reception['REMOVED'].to_i.zero?
  end

  def reception_patient_matches?(reception)
    patient_code = reception['PATIENT_CODE'].presence || reception['PROFILE_CODE'].presence

    patient_code.present? && provider_patient_code.present? && patient_code.to_s == provider_patient_code.to_s
  end

  def reception_time_matches?(reception)
    remote_time(reception['STARTTIME'])&.to_i == snapshot_time('destination_starts_at').to_i &&
      remote_time(reception['ENDTIME'])&.to_i == snapshot_time('destination_ends_at').to_i
  end

  def preflight_reception_codes
    Array(command.execution_state.to_h['preflight_reception_codes']).map(&:to_s)
  end

  def patient_snapshot_matches?(patient)
    return false unless patient['REMOVED'].to_i.zero?

    desired = patient_snapshot.fetch('payload')
    {
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
  end

  def specialist_code
    reception_snapshot.fetch('specialist_code')
  end

  def provider_patient_code
    command.execution_state.to_h['write_provider_patient_code'].presence ||
      command.request_snapshot['provider_patient_code'].presence || command.provider_patient_code
  end

  def provider_reception_code
    command.request_snapshot['provider_reception_code'].to_s
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

  def remote_time(value)
    ActiveSupport::TimeZone[reception_snapshot.fetch('time_zone')].parse(value.to_s)
  end

  def success_applier
    @success_applier ||= Integrations::Medelement::ProviderCommands::SuccessApplier.new(
      command: command,
      reconciliation_claim_token: reconciliation_claim_token
    )
  end

  def initialize_provider!
    @configuration = Integrations::Medelement::Configuration.new(hook: command.hook)
    @client = Integrations::Medelement::Client.new(configuration: configuration)
  end
end
