# frozen_string_literal: true

class Captain::Conversation::PendingActionCancellationService
  PENDING_STATUSES = %w[
    awaiting_confirmation awaiting_patient_selection awaiting_patient_creation awaiting_phone_refresh queued
  ].freeze

  def initialize(conversation:, control_owner:)
    @conversation = conversation
    @control_owner = control_owner
  end

  # Called inside the control-owner lock and the same transaction as takeover.
  # Processing/unknown remote writes must be reconciled, never marked cancelled.
  def perform
    command_class = Integrations::Medelement::ProviderCommand
    statuses = PENDING_STATUSES.flat_map { |status| command_class.execution_statuses(status) }
    conversation_ids = @control_owner.equal?(@conversation) ? [@conversation.id] : @control_owner.conversations.pluck(:id)
    return if conversation_ids.empty?

    now = Time.current
    command_class.where(account_id: @conversation.account_id, status: statuses)
                 .where("execution_state -> 'captain_action_origin' ->> 'conversation_id' IN (?)", conversation_ids.map(&:to_s))
                 .update_all( # rubocop:disable Rails/SkipsModelValidations
                   status: 'cancelled', executed_at: now, last_error_code: 'captain_control_stale',
                   last_error_status: nil, updated_at: now
                 )
  end
end
