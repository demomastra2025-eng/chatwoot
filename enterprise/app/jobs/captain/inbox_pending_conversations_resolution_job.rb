class Captain::InboxPendingConversationsResolutionJob < ApplicationJob
  CAPTAIN_INFERENCE_RESOLVE_ACTIVITY_REASON = 'no outstanding questions'.freeze
  CAPTAIN_INFERENCE_HANDOFF_ACTIVITY_REASON = 'pending clarification from customer'.freeze

  queue_as :low

  def perform(inbox)
    return if inbox.account.captain_auto_resolve_disabled?
    return if inbox.account.auto_resolve_after.blank?

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
      create_resolution_message(conversation, inbox)
      conversation.resolved!
    end
  end

  def perform_with_evaluation(inbox)
    Current.executed_by = inbox.captain_assistant

    resolvable_pending_conversations(inbox).each do |conversation|
      evaluation = evaluate_conversation(conversation, inbox)
      next unless still_resolvable_after_evaluation?(conversation)

      if evaluation[:complete]
        resolve_conversation(conversation, inbox, evaluation[:reason], generated_message: evaluation[:message])
      else
        handoff_conversation(conversation, inbox, evaluation[:reason], generated_message: evaluation[:message])
      end
    end
  end

  def evaluate_conversation(conversation, inbox)
    Captain::ConversationCompletionService.new(
      account: inbox.account,
      conversation_display_id: conversation.display_id
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

  def resolve_conversation(conversation, inbox, reason, generated_message: nil)
    create_private_note(conversation, inbox, "Auto-resolved: #{reason}")
    create_resolution_message(conversation, inbox, generated_message: generated_message)
    conversation.with_captain_activity_context(
      reason: CAPTAIN_INFERENCE_RESOLVE_ACTIVITY_REASON,
      reason_type: :inference
    ) { conversation.resolved! }
    conversation.dispatch_captain_inference_resolved_event
  end

  def handoff_conversation(conversation, inbox, reason, generated_message: nil)
    create_private_note(conversation, inbox, "Auto-handoff: #{reason}")
    create_handoff_message(conversation, inbox, generated_message: generated_message)
    conversation.with_captain_activity_context(
      reason: CAPTAIN_INFERENCE_HANDOFF_ACTIVITY_REASON,
      reason_type: :inference
    ) { conversation.bot_handoff! }
    conversation.dispatch_captain_inference_handoff_event
    send_out_of_office_message_if_applicable(conversation.reload)
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
