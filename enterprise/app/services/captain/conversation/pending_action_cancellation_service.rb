# frozen_string_literal: true

class Captain::Conversation::PendingActionCancellationService
  def initialize(conversation:, control_owner:)
    @conversation = conversation
    @control_owner = control_owner
  end

  # Called inside the control-owner lock and the same transaction as takeover.
  # Processing/unknown remote writes must be reconciled, never marked cancelled.
  def perform
    command_class = Integrations::Medelement::ProviderCommand
    statuses = Captain::Conversation::ActionFenceService::PENDING_STATUSES.flat_map { |status| command_class.execution_statuses(status) }
    conversation_ids = @control_owner.equal?(@conversation) ? [@conversation.id] : @control_owner.conversations.pluck(:id)
    return if conversation_ids.empty?

    # Own each command before its Appointment, like the reconciliation path.
    # A pending command with a write marker has an unknown remote outcome;
    # the action fence parks it for read-back instead of bulk-cancelling it.
    command_class.where(account_id: @conversation.account_id, status: statuses)
                 .where("execution_state -> 'captain_action_origin' ->> 'conversation_id' IN (?)", conversation_ids.map(&:to_s))
                 .order(:id).find_each do |command|
      Captain::Conversation::ActionFenceService.cancel_pending!(command, reason: 'captain_control_stale')
    end
  end
end
