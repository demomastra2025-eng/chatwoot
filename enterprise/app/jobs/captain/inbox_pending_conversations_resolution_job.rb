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
    resolvable_pending_conversations(inbox).each do |conversation|
      context = auto_completion_context(conversation)
      next unless context

      notice = notice_for(conversation, context[:assistant], true)
      with_current_agent(conversation, context) do |assistant|
        create_resolution_message(conversation, assistant, notice)
        transition_conversation_status!(conversation, 'resolved', actor: assistant, source: 'system')
      end
    end
  end

  # A conversation the evaluation does not find complete (including a failed
  # evaluation) leaves pending through a system handoff, so people see it and it
  # is not evaluated again every run.
  def perform_with_evaluation(inbox)
    resolvable_pending_conversations(inbox).each do |conversation|
      context = auto_completion_context(conversation)
      next unless context

      Current.executed_by = context[:assistant]
      evaluation = evaluate_conversation(conversation, inbox)

      activity_reason = evaluation[:complete] ? CAPTAIN_INFERENCE_RESOLVE_ACTIVITY_REASON : CAPTAIN_INFERENCE_HANDOFF_ACTIVITY_REASON
      # The customer notice is written by its own model (never taken from the evaluation) before any lock is held.
      notice = notice_for(conversation, context[:assistant], evaluation[:complete])
      # Status activity is created after commit, so its context must outlive the
      # transaction opened by the final ownership check.
      conversation.with_captain_activity_context(reason: activity_reason, reason_type: :inference) do
        with_current_agent(conversation, context) do |assistant|
          if evaluation[:complete]
            resolve_conversation(conversation, assistant, evaluation[:reason], notice)
          else
            handoff_conversation(conversation, assistant, evaluation[:reason], context[:fence], notice)
          end
        end
      end
    end
  end

  # The closing notice (complete) or the system handoff notice, with its text already written here, outside the
  # conversation lock, because the notice model can take seconds; a failure only means that it is written again under the lock.
  def notice_for(conversation, assistant, complete)
    notice = if complete
               Captain::CustomerNoticeService.new(conversation: conversation, assistant: assistant, kind: :resolution)
             else
               Captain::SystemHandoffMessageService.new(conversation: conversation, assistant: assistant)
             end
    notice.prepare
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][CustomerNotice] could not prepare a notice: #{e.class.name}")
    notice
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

  def auto_completion_context(conversation)
    ownership = Captain::Conversation::AgentOwnership.new(conversation: conversation)
    assistant = ownership.current_assistant
    return unless assistant&.auto_completion_enabled?

    {
      assistant: assistant,
      fence: handoff_fence(conversation).merge(entry_assistant_id: ownership.entry.id, routing_revision: ownership.routing_revision)
    }
  end

  # Evaluation runs without database locks. Only the final messages and status
  # change hold the conversation, shared control owner and inbox assignment, so
  # a transfer or reassignment cannot race the final ownership check.
  def with_current_agent(conversation, context)
    conversation.with_lock do
      conversation.with_captain_control_lock do
        Telephony::AiVoice::AssistantAssignmentLock.acquire!(conversation.inbox_id)
        ownership = Captain::Conversation::AgentOwnership.new(conversation: conversation, assistant: context[:assistant])
        fence = context[:fence]
        next unless ownership.current?(expected_entry_id: fence[:entry_assistant_id],
                                       expected_revision: fence[:routing_revision], enforce_revision: true)
        next unless control_fence_current?(conversation, fence) && still_resolvable_after_evaluation?(conversation)

        assistant = ownership.current_assistant
        next unless assistant&.auto_completion_enabled?

        Current.executed_by = assistant
        yield assistant
      end
    end
  end

  def control_fence_current?(conversation, fence)
    conversation.current_captain_control_generation.to_i == fence[:control_generation].to_i &&
      conversation.status_transitions.maximum(:id).to_i == fence[:status_transition_id].to_i
  end

  def resolve_conversation(conversation, assistant, reason, notice)
    create_private_note(conversation, assistant, "Auto-resolved: #{reason}")
    create_resolution_message(conversation, assistant, notice)
    transition_conversation_status!(conversation, 'resolved', actor: assistant, source: 'system')
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
  # workspace handoff message (when enabled and configured; written beforehand
  # by the notice service) and the open transition happen once, under the same fence.
  def handoff_conversation(conversation, assistant, reason, fence, notice)
    result = conversation.bot_handoff!(actor: assistant, source: 'system', fence: fence) do
      create_private_note(conversation, assistant, "Auto-handoff: #{reason}")

      notice.perform
    end
    return unless result == :applied

    conversation.dispatch_captain_inference_handoff_event
    # Reloading here would clear the status change before after_commit activity.
    send_out_of_office_message_if_applicable(conversation)
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

  def create_private_note(conversation, assistant, content)
    conversation.messages.create!(
      message_type: :outgoing,
      private: true,
      sender: assistant,
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      content: content
    )
  end

  # The text is the workspace closing message from the notice service: nothing while it is disabled or has no text.
  def create_resolution_message(conversation, assistant, notice)
    content = notice.text
    return if content.blank?

    I18n.with_locale(conversation.account.locale) do
      conversation.messages.create!(
        {
          message_type: :outgoing,
          account_id: conversation.account_id,
          inbox_id: conversation.inbox_id,
          content: content,
          sender: assistant
        }
      )
    end
  end
end
