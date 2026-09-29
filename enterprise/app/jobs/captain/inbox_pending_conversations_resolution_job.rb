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
      transition_conversation_status!(conversation, 'resolved', actor: inbox.captain_assistant, source: 'system')
    end
  end

  # A conversation the evaluation does not find complete (including a failed
  # evaluation) leaves pending through a system handoff, so people see it and it
  # is not evaluated again every run.
  def perform_with_evaluation(inbox)
    Current.executed_by = inbox.captain_assistant

    resolvable_pending_conversations(inbox).each do |conversation|
      fence = handoff_fence(conversation)
      evaluation = evaluate_conversation(conversation, inbox)
      next unless still_resolvable_after_evaluation?(conversation)

      if evaluation[:complete]
        resolve_conversation(conversation, inbox, evaluation[:reason], generated_message: evaluation[:message])
      else
        handoff_conversation(conversation, inbox, evaluation[:reason], fence, generated_message: evaluation[:message])
      end
    end
  end

  def evaluate_conversation(conversation, inbox)
    Captain::ConversationCompletionService.new(
      account: inbox.account,
      conversation_display_id: conversation.display_id
    ).perform
  end

  # Oldest activity first, so a batch never keeps skipping the conversations
  # that have waited longest.
  def resolvable_pending_conversations(inbox)
    cutoff_time = auto_resolve_cutoff_time(inbox.account)
    return Conversation.none unless cutoff_time

    inbox.conversations.pending
         .where('last_activity_at < ?', cutoff_time)
         .reorder(last_activity_at: :asc, id: :asc)
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
    ) { transition_conversation_status!(conversation, 'resolved', actor: inbox.captain_assistant, source: 'system') }
    conversation.dispatch_captain_inference_resolved_event
  end

  # Taken before the evaluation: a human takeover, a staff release or any other
  # status change while the evaluation runs makes the handoff stale. The last
  # message is left out on purpose: a staff reply in another channel of the
  # thread keeps this conversation pending and must not block its handoff.
  def handoff_fence(conversation)
    {
      control_generation: conversation.current_captain_control_generation.to_i,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i
    }
  end

  # System safety net, independent of the handoff tool: the note, the
  # assistant's own handoff message (when enabled and configured) and the open
  # transition happen once, under the same fence.
  def handoff_conversation(conversation, inbox, reason, fence, generated_message: nil)
    assistant = inbox.captain_assistant
    result = conversation.with_captain_activity_context(reason: CAPTAIN_INFERENCE_HANDOFF_ACTIVITY_REASON, reason_type: :inference) do
      conversation.bot_handoff!(actor: assistant, source: 'system', fence: fence) do
        create_private_note(conversation, inbox, "Auto-handoff: #{reason}")
        next if assistant.blank?

        Captain::SystemHandoffMessageService.new(conversation: conversation, assistant: assistant, generated_message: generated_message).perform
      end
    end
    return unless result == :applied

    conversation.dispatch_captain_inference_handoff_event
    send_out_of_office_message_if_applicable(conversation.reload)
  end

  def send_out_of_office_message_if_applicable(conversation)
    # Campaign conversations should never receive OOO templates — the campaign itself
    # serves as the initial outreach, and OOO would be confusing in that context.
    return if conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation)
  end

  def transition_conversation_status!(conversation, status, actor:, source:)
    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: { status: status },
      actor: actor,
      source: source
    ).perform
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
end
