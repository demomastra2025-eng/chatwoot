class Captain::InboxPendingConversationsResolutionJob < ApplicationJob
  CAPTAIN_INFERENCE_RESOLVE_ACTIVITY_REASON = 'no outstanding questions'.freeze
  CAPTAIN_INFERENCE_HANDOFF_ACTIVITY_REASON = 'pending clarification from customer'.freeze
  TIME_BASED_COMPLETION_EXPLANATION = 'Customer did not respond within the configured inactivity period.'.freeze

  queue_as :low

  def perform(inbox)
    inbox.captain_assistant&.reload
    return if inbox.account.captain_auto_resolve_disabled?
    return if inbox.account.auto_resolve_after.blank?
    return unless inbox.captain_assistant&.auto_completion_enabled?

    if evaluate_conversation_completion?(inbox.account)
      perform_with_evaluation(inbox)
    else
      perform_time_based(inbox)
    end
  ensure
    Current.reset
  end

  private

  def evaluate_conversation_completion?(account)
    account.feature_enabled?('captain_tasks') && account.captain_auto_resolve_evaluated?
  end

  def perform_time_based(inbox)
    Current.executed_by = inbox.captain_assistant

    resolvable_pending_conversations(inbox).each do |conversation|
      conversation.with_lock do
        transition_conversation_status!(conversation, 'resolved', actor: inbox.captain_assistant, source: 'system')
        create_private_note(conversation, inbox, "Auto-resolved: #{TIME_BASED_COMPLETION_EXPLANATION}")
        create_resolution_message(conversation, inbox)
      end
    end
  end

  def perform_with_evaluation(inbox)
    Current.executed_by = inbox.captain_assistant

    resolvable_pending_conversations(inbox).each do |conversation|
      evaluation = evaluate_conversation(conversation, inbox)
      next unless evaluation[:evaluated] == true
      next unless still_resolvable_after_evaluation?(conversation)

      apply_evaluation(conversation, inbox, evaluation)
    end
  end

  def apply_evaluation(conversation, inbox, evaluation)
    method = evaluation[:complete] ? :resolve_conversation : :handoff_conversation
    send(
      method,
      conversation,
      inbox,
      evaluation[:reason],
      status_reason: evaluation[:status_reason],
      generated_message: evaluation[:message]
    )
  end

  def evaluate_conversation(conversation, inbox)
    Captain::ConversationCompletionService.new(
      account: inbox.account,
      conversation_display_id: conversation.display_id,
      outcome_reasons: Captain::OutcomeReasonConfig.new(inbox.captain_assistant).prompt_context
    ).perform
  end

  def resolvable_pending_conversations(inbox)
    cutoff_time = auto_resolve_cutoff_time(inbox.account)
    return Conversation.none unless cutoff_time

    inbox.conversations.pending
         .where('last_activity_at < ?', cutoff_time)
         .limit(Limits::BULK_ACTIONS_LIMIT)
  end

  def still_resolvable_after_evaluation?(conversation)
    cutoff_time = auto_resolve_cutoff_time(conversation.account)
    return false unless cutoff_time

    conversation.reload
    conversation.pending? && conversation.last_activity_at < cutoff_time
  rescue ActiveRecord::RecordNotFound
    false
  end

  def auto_resolve_cutoff_time(account)
    auto_resolve_after = account.auto_resolve_after.to_i
    return if auto_resolve_after <= 0

    Time.now.utc - auto_resolve_after.minutes
  end

  def resolve_conversation(conversation, inbox, reason, status_reason: nil, generated_message: nil)
    raise ArgumentError, 'A specific completion explanation is required' if reason.to_s.squish.blank?

    conversation.with_lock do
      transition_agent_outcome(conversation, inbox.captain_assistant, :completion, status_reason, explanation: reason)
      create_private_note(conversation, inbox, "Auto-resolved: #{reason}")
      create_resolution_message(conversation, inbox, generated_message: generated_message)
    end
    conversation.dispatch_captain_inference_resolved_event
  end

  def handoff_conversation(conversation, inbox, reason, status_reason: nil, generated_message: nil)
    return unless inbox.captain_assistant&.handoff_enabled?

    raise ArgumentError, 'A specific handoff explanation is required' if reason.to_s.squish.blank?

    conversation.with_lock do
      transition_agent_outcome(conversation, inbox.captain_assistant, :handoff, status_reason, explanation: reason)
      create_private_note(conversation, inbox, "Auto-handoff: #{reason}")
      create_handoff_message(conversation, inbox, generated_message: generated_message)
    end
    conversation.dispatch_captain_inference_handoff_event
    send_out_of_office_message_if_applicable(conversation.reload)
  end

  def transition_agent_outcome(conversation, assistant, type, status_reason, explanation:)
    transition_options = outcome_transition_options(assistant, type, status_reason, explanation: explanation)
    activity_reason = type == :completion ? CAPTAIN_INFERENCE_RESOLVE_ACTIVITY_REASON : CAPTAIN_INFERENCE_HANDOFF_ACTIVITY_REASON
    Current.executed_by = assistant
    conversation.captain_activity_reason = activity_reason
    conversation.captain_activity_reason_type = :inference

    if type == :completion
      transition_conversation_status!(conversation, 'resolved', actor: assistant, source: 'captain', **transition_options)
    else
      conversation.bot_handoff!(actor: assistant, source: 'captain', **transition_options)
    end
  end

  def transition_conversation_status!(conversation, status, actor:, source:, **transition_options)
    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: { status: status },
      actor: actor,
      source: source,
      **transition_options
    ).perform
  end

  def outcome_transition_options(assistant, type, reason, explanation: nil)
    config = Captain::OutcomeReasonConfig.new(assistant)
    config.transition_options(type, config.resolve(type, reason), explanation: explanation)
  end

  def send_out_of_office_message_if_applicable(conversation)
    # Campaign conversations should never receive OOO templates — the campaign itself
    # serves as the initial outreach, and OOO would be confusing in that context.
    return if conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation)
  end

  def create_private_note(conversation, inbox, content)
    conversation.messages.create!(
      message_type: :outgoing,
      private: true,
      sender: inbox.captain_assistant,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      content: content
    )
  end

  def create_resolution_message(conversation, inbox, generated_message: nil)
    assistant = inbox.captain_assistant
    return unless assistant&.resolution_message_enabled?

    I18n.with_locale(inbox.account.locale) do
      content = resolution_message_content(assistant, generated_message: generated_message)
      return if content.blank?

      conversation.messages.create!(
        {
          message_type: :outgoing,
          account_id: conversation.account_id,
          inbox_id: conversation.inbox_id,
          content: assistant.render_runtime_text(content, conversation: conversation),
          sender: assistant
        }
      )
    end
  end

  def resolution_message_content(assistant, generated_message: nil)
    return generated_message.presence if assistant.resolution_message_mode_value == Captain::Assistant::MESSAGE_MODE_AI

    assistant.config['resolution_message'].presence
  end

  def create_handoff_message(conversation, inbox, generated_message: nil)
    assistant = inbox.captain_assistant
    return unless assistant&.handoff_message_enabled?

    handoff_message = handoff_message_content(assistant, generated_message: generated_message)
    return if handoff_message.blank?

    conversation.messages.create!(
      message_type: :outgoing,
      sender: assistant,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      content: assistant.render_runtime_text(handoff_message, conversation: conversation),
      preserve_waiting_since: true
    )
  end

  def handoff_message_content(assistant, generated_message: nil)
    return generated_message.presence if assistant.handoff_message_mode_value == Captain::Assistant::MESSAGE_MODE_AI

    assistant.config['handoff_message'].presence
  end
end
