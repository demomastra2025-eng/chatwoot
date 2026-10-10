# Acknowledged creates remain successful while MedElement's read API catches up. This path
# only reads the provider and records verification metadata; it never reapplies an appointment or POSTs.
class Integrations::Medelement::ProviderCommands::ReceptionReceiptVerificationService
  STATE_KEY = 'create_receipt_verification'.freeze
  MATERIALIZED_COMMAND_KEY = 'medelement_create_receipt_materialized_command_id'.freeze
  MAX_ATTEMPTS = 6
  BACKOFFS = [1.minute, 5.minutes, 15.minutes, 1.hour, 4.hours].freeze
  CHECK_LEASE = 2.minutes

  def self.applicable?(command)
    reference = command.execution_state.to_h['write_provider_reception_code']
    command.create_reception? && command.succeeded? &&
      Integrations::Medelement::ProviderCommands::ReceptionVerifier.valid_reception_code?(reference) &&
      command.provider_reception_code.to_s == reference.to_s && command.provider_patient_code.present?
  end

  # Only new immediate acknowledgements have this state. Legacy read-confirmed successes keep
  # their existing absence reconciliation. No elapsed time or exhausted read budget proves absence.
  def self.unmaterialized_current_create?(appointment)
    command = current_acknowledged_create(appointment)
    command.present? && command.execution_state[STATE_KEY]['status'] != 'verified' &&
      appointment.custom_attributes.to_h[MATERIALIZED_COMMAND_KEY].to_s != command.id.to_s
  end

  def self.materialization_attributes(appointment, reception)
    command = current_acknowledged_create(appointment)
    return {} unless command

    patient_codes = [reception['PATIENT_CODE'], reception['PROFILE_CODE']].filter_map { |value| value.to_s.presence }.uniq
    return {} unless reception['RECEPTION_CODE'].to_s == command.provider_reception_code.to_s &&
                     patient_codes == [command.provider_patient_code.to_s]

    { MATERIALIZED_COMMAND_KEY => command.id }
  end

  def self.current_acknowledged_create(appointment)
    attributes = appointment.custom_attributes.to_h
    provider = Integrations::Medelement::AppointmentProviderStatus
    return unless attributes[provider::ATTRIBUTE_KEY] == provider::SUCCEEDED &&
                  attributes[provider::OPERATION_KEY] == 'create_reception' && attributes[provider::COMMAND_ID_KEY].present?

    command = Integrations::Medelement::ProviderCommand.find_by(
      id: attributes[provider::COMMAND_ID_KEY], account_id: appointment.account_id, appointment_id: appointment.id,
      operation: 'create_reception', status: 'succeeded'
    )
    return unless command && command.execution_state.to_h[STATE_KEY].is_a?(Hash) && applicable?(command) &&
                  provider.bound_to_command?(appointment, command) &&
                  attributes['medelement_reception_code'].to_s == command.provider_reception_code.to_s &&
                  appointment.external_ref.to_s == "medelement:reception:#{command.provider_reception_code}"

    command
  end
  private_class_method :current_acknowledged_create

  def initialize(command:, client: nil)
    @command = command
    @client = client
  end

  def perform
    return unless claim_check!

    finish_check!(verified? ? 'verified' : 'pending')
  rescue Integrations::Medelement::Client::ApiError
    finish_check!('pending', reason: 'provider_unavailable')
  rescue StandardError => e
    Rails.logger.warn("[MEDELEMENT::RECEIPT_VERIFICATION] command_id=#{command.id} error=#{e.class.name}")
    finish_check!('pending', reason: 'verification_internal_error')
  end

  private

  attr_reader :command

  def claim_check!
    command.with_lock do
      command.reload
      next false unless self.class.applicable?(command)

      state = verification_state
      next false if state['status'] == 'verified' || state['attempts'].to_i >= MAX_ATTEMPTS
      next false if state['next_at'].present? && Time.iso8601(state['next_at']) > Time.current

      @attempt = state['attempts'].to_i + 1
      command.update!(execution_state: command.execution_state.to_h.merge(STATE_KEY => {
        'status' => 'pending', 'attempts' => @attempt, 'checked_at' => Time.current.iso8601,
        'next_at' => (Time.current + CHECK_LEASE).iso8601
      }))
      true
    end
  end

  def verified?
    return false unless command.request_snapshot_valid? && command.confirmation_matches_request_snapshot?

    hook = command.hook
    return false unless hook&.enabled? && hook.feature_allowed?

    configuration = Integrations::Medelement::Configuration.new(hook: hook)
    return false unless configuration.organization_id.to_s == command.request_snapshot['organization_id'].to_s

    @client ||= Integrations::Medelement::Client.new(configuration: configuration)
    detail = @client.get_reception(reception_code: command.provider_reception_code, version: :v2)
    return true if verifier.destination_match?(detail, expected_reception_code: command.provider_reception_code)

    scoped = destination_receptions.find do |row|
      verifier.reference_matches?(row, expected_code: command.provider_reception_code)
    end
    scoped.present? && verifier.destination_match?(scoped.merge(detail.to_h), expected_reception_code: command.provider_reception_code)
  end

  def verifier
    @verifier ||= Integrations::Medelement::ProviderCommands::ReceptionVerifier.new(
      command: command, provider_patient_code: command.provider_patient_code
    )
  end

  def destination_receptions
    reception = command.request_snapshot.fetch('reception')
    zone = ActiveSupport::TimeZone[reception.fetch('time_zone')]
    starts_on = Time.iso8601(reception.fetch('destination_starts_at')).in_time_zone(zone).to_date
    ends_on = Time.iso8601(reception.fetch('destination_ends_at')).in_time_zone(zone).to_date + 1.day
    @client.get_receptions(
      company_cabinet_code: command.request_snapshot.fetch('company_cabinet_code'),
      specialist_code: reception.fetch('specialist_code'),
      begin_datetime: zone.local(starts_on.year, starts_on.month, starts_on.day).strftime('%d.%m.%Y %H:%M:%S'),
      end_datetime: zone.local(ends_on.year, ends_on.month, ends_on.day).strftime('%d.%m.%Y %H:%M:%S')
    )
  end

  def finish_check!(status, reason: nil)
    return unless @attempt

    next_at = Time.current + BACKOFFS.fetch(@attempt - 1, BACKOFFS.last) if status != 'verified' && @attempt < MAX_ATTEMPTS
    command.with_lock do
      command.reload
      next unless self.class.applicable?(command) && verification_state['attempts'] == @attempt

      state = verification_state.merge('status' => status, 'reason' => reason || (status == 'pending' ? 'read_not_materialized' : nil),
                                       'next_at' => next_at&.iso8601).compact
      command.update!(execution_state: command.execution_state.to_h.merge(STATE_KEY => state))
    end
    Integrations::Medelement::ProviderCommandReconciliationJob.set(wait_until: next_at).perform_later(command.id) if next_at
  end

  def verification_state
    command.execution_state.to_h[STATE_KEY].to_h
  end
end
