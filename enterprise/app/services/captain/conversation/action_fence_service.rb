# frozen_string_literal: true

# Captain's customer scope permits local Contact/customer-task effects only.
# A durable MedElement command can outlive the tool run and its human takeover;
# neither its confirmation nor an old queued job authorizes a remote write.
class Captain::Conversation::ActionFenceService
  ORIGIN_KEY = 'captain_action_origin'
  UNAVAILABLE_CODE = 'captain_provider_contract_unavailable'
  PARTIAL_WRITE_REASON = 'captain_provider_write_partial'
  PENDING_STATUSES = %w[
    awaiting_confirmation awaiting_patient_selection awaiting_patient_creation awaiting_phone_refresh queued
  ].freeze

  ORIGIN_CONTEXT_KEY = :captain_action_origin

  def self.current_origin
    ActiveSupport::IsolatedExecutionState[ORIGIN_CONTEXT_KEY]
  end

  def initialize(assistant:, state:)
    @assistant = assistant
    @state = state.to_h.with_indifferent_access
  end

  # Keep an action and human takeover on the same contact -> shared-owner lock
  # path. The read-only tools intentionally do not acquire these locks.
  def with_effect!(&)
    fence = @state[:captain_response_fence]
    return yield if fence.blank? && @state.dig(:conversation, :id).blank?

    conversation = Conversation.where(account_id: @state[:account_id]).find_by(id: @state.dig(:conversation, :id))
    raise Captain::Conversation::ControlGenerationStaleError, 'Captain conversation is missing before action' unless conversation

    Conversation.transaction do
      # The customer-tool boundary and Contact merge acquire the account phone
      # identity lock before the advisory; take it first here as well because
      # the tool boundary re-enters under this fence.
      Contacts::PhoneIdentityLock.acquire!(account_id: conversation.account_id)
      Conversations::CommunicationThreadResolver.lock_contact_thread!(conversation.account_id, conversation.contact_id)
      # Direct Contact owner callbacks hold Contact before Team/Thread. Acquire
      # it before the Captain owner to avoid owner -> Contact inversion.
      Contact.where(account_id: conversation.account_id).lock.find(conversation.contact_id)
      conversation.with_captain_control_lock do
        ensure_current!(conversation, fence)
        with_origin(conversation, fence, &)
      end
    end
  end

  def self.origin_for(actor_descriptor:, appointment:)
    actor = actor_descriptor.to_h.deep_stringify_keys
    return unless actor['type'] == 'Captain::Assistant'

    # This marker is provenance, not a fresh owner proof. A queued command must
    # never infer authorization from the latest generation at dispatch time.
    {
      'source' => 'captain_actor',
      'assistant_id' => actor['id'],
      'conversation_id' => appointment&.conversation_id
    }.compact
  end

  def self.captain_command?(command)
    command.execution_state.to_h.key?(ORIGIN_KEY) ||
      command.request_snapshot['actor'].to_h['type'] == 'Captain::Assistant'
  end

  # Do not cancel processing/reconciliation/unknown: a write may have reached
  # the provider. Those states retain the existing read-back-only lifecycle.
  def self.cancel_pending!(command, reason: UNAVAILABLE_CODE)
    return false unless captain_command?(command)

    # Projection and reconciliation both own ProviderCommand before they update
    # Appointment. Locking Appointment first deadlocks a concurrent projection.
    command.with_lock do
      next false unless PENDING_STATUSES.include?(command.logical_status)

      appointment = command.appointment
      if appointment
        appointment.with_lock { cancel_locked!(command, appointment: appointment, reason: reason) }
      else
        cancel_locked!(command, reason: reason)
      end
    end
  end

  def self.ensure_executor_allowed!(command)
    return unless captain_command?(command)

    raise Integrations::Medelement::ProviderCommands::ExecutionError.new(
      code: UNAVAILABLE_CODE,
      message: 'Customer AI provider writes are not authorized',
      reconciliation: command.execution_state.to_h['write_phase'].present?
    )
  end

  # Reconciliation found a remote patient, but must never enqueue the next
  # Captain reception write. Own Command before Appointment, like projection.
  def self.park_partial_patient!(command, patient_code:, claim_token: nil)
    return false unless captain_command?(command)

    command.with_lock do
      next false unless command.processing?
      next false if claim_token.present? &&
                    command.execution_state.to_h[Integrations::Medelement::ProviderCommands::ReconciliationLifecycle::CLAIM_TOKEN_KEY] != claim_token

      appointment = command.appointment
      if appointment
        appointment.with_lock do
          mark_partial_unknown!(command, provider_patient_code: patient_code)
          project_status!(appointment, command, Integrations::Medelement::AppointmentProviderStatus::UNKNOWN)
        end
      else
        mark_partial_unknown!(command, provider_patient_code: patient_code)
      end
      false
    end
  end

  def self.cancel_locked!(command, appointment: nil, reason: UNAVAILABLE_CODE)
    provider_status = if command.execution_state.to_h['write_phase'].present?
                        mark_partial_unknown!(command)
                        Integrations::Medelement::AppointmentProviderStatus::UNKNOWN
                      else
                        command.update!(status: 'cancelled', executed_at: Time.current, last_error_code: reason, last_error_status: nil)
                        Integrations::Medelement::AppointmentProviderStatus::FAILED
                      end
    project_status!(appointment, command, provider_status)
    true
  end
  private_class_method :cancel_locked!

  def self.mark_partial_unknown!(command, provider_patient_code: command.provider_patient_code)
    lifecycle = Integrations::Medelement::ProviderCommands::ReconciliationLifecycle
    state = command.execution_state.to_h.except(lifecycle::CLAIM_TOKEN_KEY, lifecycle::CLAIMED_AT_KEY, 'reconciliation_next_at')
    command.update!(
      status: command.status_for_transition('provider_status_unknown'),
      provider_patient_code: provider_patient_code,
      last_error_code: 'provider_status_unknown',
      last_error_status: nil,
      execution_state: state.merge(
        'provider_status_unknown_reason' => PARTIAL_WRITE_REASON,
        'reconciliation_next_at' =>
          (Time.current + Integrations::Medelement::ProviderCommand::PROVIDER_STATUS_UNKNOWN_BACKOFF).iso8601
      )
    )
  end
  private_class_method :mark_partial_unknown!

  def self.project_status!(appointment, command, status)
    return unless appointment && appointment_current?(appointment, command)

    Integrations::Medelement::AppointmentProviderStatus.persist!(appointment, status, command: command)
  end
  private_class_method :project_status!

  def self.appointment_current?(appointment, command)
    current_id = appointment.custom_attributes.to_h[Integrations::Medelement::AppointmentProviderStatus::COMMAND_ID_KEY]
    current_id.blank? || current_id.to_s == command.id.to_s
  end
  private_class_method :appointment_current?

  private

  def ensure_current!(conversation, fence)
    if fence.present?
      Captain::Conversation::RunFenceService.new(assistant: @assistant, state: @state, stage: 'tool_effect').ensure_current!
      return
    end

    raise Captain::Conversation::ControlGenerationStaleError, 'Captain control changed before action' unless control_generation_allowed?(conversation)
  end

  def control_generation_allowed?(conversation)
    expected = @state[:captain_control_generation]
    expected.present? && @assistant.present? &&
      conversation.inbox.captain_assistant&.id == @assistant.id &&
      !conversation.captain_human_control_active? &&
      conversation.current_captain_control_generation.to_i == expected.to_i
  end

  def with_origin(conversation, fence)
    previous = self.class.current_origin
    ActiveSupport::IsolatedExecutionState[ORIGIN_CONTEXT_KEY] = {
      'assistant_id' => @assistant&.id,
      'conversation_id' => conversation.id,
      'control_generation' => fence&.dig(:control_generation) || @state[:captain_control_generation]
    }
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[ORIGIN_CONTEXT_KEY] = previous
  end
end
