module Enterprise::Api::V1::Accounts::ConversationsController
  extend ActiveSupport::Concern

  def toggle_status
    previous_status = @conversation.status

    super

    clear_captain_typing_indicator(previous_status)
    trigger_captain_auto_reply_for_last_incoming(previous_status)
  end

  def inbox_assistant
    assistant = @conversation.inbox.captain_assistant

    if assistant
      render json: { assistant: { id: assistant.id, name: assistant.name } }
    else
      render json: { assistant: nil }
    end
  end

  def cancel_captain_response
    assistant = @conversation.inbox.captain_assistant
    return render json: { error: 'Captain assistant not found' }, status: :not_found unless assistant

    Captain::Conversation::ResponseCancellationService.new(
      conversation: @conversation,
      assistant: assistant,
      actor: Current.user
    ).perform(reason: params[:reason])

    render json: { response_cancelled: true }
  end

  def reporting_events
    @reporting_events = @conversation.reporting_events.order(created_at: :asc)
  end

  def permitted_update_params
    super.merge(params.permit(:sla_policy_id))
  end

  private

  def trigger_captain_auto_reply_for_last_incoming(previous_status)
    return unless should_auto_reply_with_captain?(previous_status)

    assistant = @conversation.inbox.captain_assistant
    last_incoming_message = latest_public_incoming_message
    return unless assistant.present? && last_incoming_message.present?

    Captain::Conversation::TypingIndicatorService.turn_on(
      conversation: @conversation,
      assistant: assistant
    )
    Captain::Conversation::ResponseBuilderJob.perform_later(
      @conversation,
      assistant,
      expected_last_message_id: last_incoming_message.id
    )
  end

  def should_auto_reply_with_captain?(previous_status)
    return false unless user_reopened_pending_conversation?(previous_status)
    return false unless captain_available_for_auto_reply?

    latest_public_message&.incoming?
  end

  def clear_captain_typing_indicator(previous_status)
    return unless previous_status == 'pending' || previous_status == Conversation.statuses[:pending]
    return if @conversation.pending?

    captain_assistant = ::CaptainInbox.find_by(inbox_id: @conversation.inbox_id)&.captain_assistant
    Captain::Conversation::TypingIndicatorService.turn_off(
      conversation: @conversation,
      assistant: captain_assistant
    )
  end

  def latest_public_incoming_message
    message = latest_public_message
    return unless message&.incoming?

    message
  end

  def user_reopened_pending_conversation?(previous_status)
    Current.user.is_a?(User) &&
      params[:status] == 'pending' &&
      previous_status != 'pending' &&
      @conversation.pending?
  end

  def captain_available_for_auto_reply?
    assistant = @conversation.inbox&.captain_assistant
    assistant&.auto_reply_on_last_incoming_enabled? &&
      @conversation.inbox&.captain_active? &&
      @conversation.inbox&.captain_auto_reply_allowed?
  end

  def latest_public_message
    @conversation.messages
                 .where(message_type: [:incoming, :outgoing])
                 .where(private: false)
                 .last
  end

  def copilot_params
    params.permit(:previous_history, :message, :assistant_id)
  end
end
