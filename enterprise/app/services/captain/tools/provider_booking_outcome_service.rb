class Captain::Tools::ProviderBookingOutcomeService
  WAIT_SECONDS = 45
  POLL_SECONDS = 0.25
  STATUS = Integrations::Medelement::AppointmentProviderStatus
  PATIENT_ACTION_STATUSES = %w[awaiting_patient_selection awaiting_patient_creation awaiting_phone_refresh].freeze

  def self.write_receipt?(command)
    state = command.execution_state.to_h
    reference = state['write_provider_reception_code']
    patient_code = command.provider_patient_code.presence || state['write_provider_patient_code'].presence
    Integrations::Medelement::ProviderCommands::ReceptionVerifier.valid_reception_code?(reference) && patient_code.present? &&
      command.provider_reception_code.to_s == reference.to_s
  end

  def initialize(appointment:, assistant:, response_fence: nil)
    @appointment = appointment
    @assistant = assistant
    @response_fence = response_fence
  end

  # Observe only the command created by this booking. An unknown result must never
  # trigger another provider write: the first POST may have succeeded.
  def perform
    return unless provider_write_required?

    @command = appointment.medelement_provider_command_receipt
    return missing_receipt! if command.blank?

    Captain::Tools::ProviderBookingHandoffService.capture_fence!(command: command, fence: @response_fence)
    wait_for_write!
  end

  private

  attr_reader :appointment, :assistant, :command

  def provider_write_required?
    return true if appointment.custom_attributes.to_h[STATUS::ATTRIBUTE_KEY].present?
    return false if appointment.resource&.custom_attributes.to_h['medelement_specialist_code'].blank?

    hook = appointment.account.hooks.enabled.find_by(app_id: 'medelement')
    hook&.feature_allowed? && Integrations::Medelement::Configuration.new(hook: hook).write_enabled?
  end

  def missing_receipt!
    STATUS.persist!(appointment, STATUS::UNKNOWN) if appointment.custom_attributes.to_h[STATUS::ATTRIBUTE_KEY] == STATUS::PENDING
    raise booking_error('MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE', 'Medelement booking command is unavailable; staff verification is required')
  end

  def wait_for_write!
    deadline = monotonic_now + WAIT_SECONDS
    loop do
      command.reload
      appointment.reload
      return command if confirmed_write?
      raise booking_error('MEDELEMENT_BOOKING_SUPERSEDED', 'Medelement booking was superseded') unless current_binding?

      fail_unacknowledged! if failed?
      return unknown_result! if command.succeeded? || unresolved? || monotonic_now >= deadline

      sleep(POLL_SECONDS)
    end
  end

  def unknown_result!
    mark_status_if_current!(STATUS::UNKNOWN)
    raise booking_error('MEDELEMENT_BOOKING_UNKNOWN', 'Medelement booking result is unknown; staff verification is required')
  end

  def fail_unacknowledged!
    mark_status_if_current!(STATUS::FAILED)
    raise booking_error('MEDELEMENT_BOOKING_FAILED', 'Medelement booking failed; staff verification is required')
  end

  def mark_status_if_current!(status)
    command.with_lock do
      appointment.with_lock do
        next unless current_binding? && !write_acknowledged?
        next if appointment.custom_attributes.to_h[STATUS::ATTRIBUTE_KEY] == STATUS::SUCCEEDED

        STATUS.persist!(appointment, status, command: command)
      end
    end
  end

  def acknowledged_and_current?
    command.with_lock do
      appointment.with_lock do
        raise booking_error('MEDELEMENT_BOOKING_SUPERSEDED', 'Medelement booking was superseded') unless current_binding?

        write_acknowledged?
      end
    end
  end

  def confirmed_write?
    write_acknowledged? && acknowledged_and_current?
  end

  def current_binding?
    state = command.execution_state.to_h
    attrs = appointment.custom_attributes.to_h
    snapshot = command.request_snapshot
    appointment.status.in?(%w[scheduled confirmed]) && current_command_identity?(snapshot) &&
      current_actor_and_time?(snapshot) && current_status_binding?(state, attrs) && current_target?
  rescue ArgumentError, TypeError, KeyError
    false
  end

  def current_target?
    guard = Integrations::Medelement::ProviderCommands::ReceptionDiscoveryGuard.new(command: command)
    guard.current_booking?(allow_completed: true)
  end

  def current_command_identity?(snapshot)
    command.create_reception? && command.account_id == appointment.account_id &&
      command.appointment_id == appointment.id && command.contact_id == appointment.contact_id &&
      snapshot['conversation_id'].present? && snapshot['conversation_id'].to_s == appointment.conversation_id.to_s
  end

  def current_actor_and_time?(snapshot)
    snapshot.dig('actor', 'type') == 'Captain::Assistant' && snapshot.dig('actor', 'id').to_s == assistant.id.to_s &&
      Time.iso8601(snapshot.dig('reception', 'destination_starts_at')) == appointment.starts_at
  end

  def current_status_binding?(state, attrs)
    attrs[STATUS::COMMAND_ID_KEY].to_s == command.id.to_s &&
      attrs[STATUS::COMMAND_IDEMPOTENCY_KEY].present? && attrs[STATUS::COMMAND_IDEMPOTENCY_KEY] == command.idempotency_key &&
      attrs[STATUS::COMMAND_FINGERPRINT_KEY].present? && attrs[STATUS::COMMAND_FINGERPRINT_KEY] == state['request_fingerprint'] &&
      attrs[STATUS::COMMAND_DISPATCH_IDENTITY_KEY].present? && attrs[STATUS::COMMAND_DISPATCH_IDENTITY_KEY] == state['dispatch_identity']
  end

  def write_acknowledged?
    self.class.write_receipt?(command) && !command.status.in?(%w[failed declined cancelled])
  end

  def failed?
    command.status.in?(%w[failed declined cancelled]) || PATIENT_ACTION_STATUSES.include?(command.logical_status)
  end

  def unresolved?
    command.provider_status_unknown? || command.reconciliation_required?
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def booking_error(code, message)
    Scheduling::Error.new(code: code, message: message, status: :unprocessable_content)
  end
end
