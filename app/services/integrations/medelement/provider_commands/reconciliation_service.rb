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
    @configuration = Integrations::Medelement::Configuration.new(hook: command.hook)
    @client = Integrations::Medelement::Client.new(configuration: @configuration)
  end

  def perform
    return unless command.reconciliation_required?

    handler = PHASE_HANDLERS[write_phase]
    send(handler) if handler
  rescue Integrations::Medelement::Client::ApiError
    nil
  rescue StandardError => e
    Rails.logger.warn("[MEDELEMENT::RECONCILIATION] command_id=#{command.id} error=#{e.class}")
    nil
  end

  private

  attr_reader :command, :configuration, :client

  def write_phase
    command.execution_state.to_h['write_phase']
  end

  def reconcile_patient_create
    code = Integrations::Medelement::ProviderCommands::PatientResolver.new(command: command, client: client).resolve!(allow_create: false)
    if command.create_reception?
      command.update!(status: 'queued', last_error_code: nil, last_error_status: nil)
      Integrations::Medelement::ProviderCommandJob.perform_later(command.id)
    else
      success_applier.patient!(patient_code: code)
    end
  rescue Integrations::Medelement::ProviderCommands::ExecutionError
    nil
  end

  def reconcile_patient_update
    matches = client.search_patients_by_phone(phone_number: command.contact.phone_number)
    patient = matches.find { |record| record['PROFILE_CODE'].to_s == command.provider_patient_code.to_s }
    return unless patient.present? && patient_snapshot_matches?(patient)

    success_applier.patient!(patient_code: command.provider_patient_code)
  end

  def reconcile_reception_create
    candidates = destination_receptions.reject do |reception|
      preflight_reception_codes.include?(reception['RECEPTION_CODE'].to_s) || !exact_destination_match?(reception)
    end
    return unless candidates.one?

    reception_code = candidates.first['RECEPTION_CODE'].to_s
    return if reception_code.blank?

    success_applier.reception_created!(reception_code: reception_code)
  end

  def reconcile_reception_move
    reception = client.get_reception(reception_code: command.provider_reception_code)
    return unless remote_reception_identity_matches?(reception)
    return unless remote_time(reception['STARTTIME'])&.to_i == command.desired_starts_at.to_i
    return unless remote_time(reception['ENDTIME'])&.to_i == command.desired_ends_at.to_i

    success_applier.reception_moved!
  end

  def remote_reception_identity_matches?(reception)
    patient_code = reception['PROFILE_CODE'].presence || reception['PATIENT_CODE'].presence

    reception.key?('REMOVED') && reception['REMOVED'].to_i.zero? &&
      patient_code.present? && reception['SPECIALIST_CODE'].present? &&
      patient_code.to_s == command.provider_patient_code.to_s &&
      reception['SPECIALIST_CODE'].to_s == specialist_code.to_s
  end

  def reconcile_reception_remove
    reception = client.get_reception(reception_code: command.provider_reception_code)
    success_applier.reception_removed! if reception['REMOVED'].to_i == 1
  end

  def destination_receptions
    client.get_receptions(
      company_cabinet_code: command.company_cabinet_code,
      specialist_code: specialist_code,
      begin_datetime: provider_datetime(command.appointment.starts_at),
      end_datetime: provider_datetime(command.appointment.ends_at)
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

    patient_code.present? && command.provider_patient_code.present? && patient_code.to_s == command.provider_patient_code.to_s
  end

  def reception_time_matches?(reception)
    remote_time(reception['STARTTIME'])&.to_i == command.appointment.starts_at.to_i &&
      remote_time(reception['ENDTIME'])&.to_i == command.appointment.ends_at.to_i
  end

  def preflight_reception_codes
    Array(command.execution_state.to_h['preflight_reception_codes']).map(&:to_s)
  end

  def patient_snapshot_matches?(patient)
    return false unless patient['REMOVED'].to_i.zero?

    desired = Integrations::Medelement::ProviderCommands::PatientPayloadBuilder.new(
      contact: command.contact,
      patient_code: command.provider_patient_code
    ).build
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
    command.appointment.resource.custom_attributes.to_h.fetch('medelement_specialist_code')
  end

  def provider_datetime(value)
    value.in_time_zone(configuration.time_zone).strftime('%d.%m.%Y %H:%M:%S')
  end

  def remote_time(value)
    ActiveSupport::TimeZone[configuration.time_zone].parse(value.to_s)
  end

  def success_applier
    @success_applier ||= Integrations::Medelement::ProviderCommands::SuccessApplier.new(command: command)
  end
end
