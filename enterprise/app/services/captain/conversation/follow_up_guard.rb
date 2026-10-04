# frozen_string_literal: true

class Captain::Conversation::FollowUpGuard
  CONTROL_FENCE_KEYS = %w[control_generation status_transition_id last_message_id].freeze

  def self.control_fence_for(reminder:, conversation:, assistant:, anchor_message:)
    new(reminder: reminder, conversation: conversation, assistant: assistant, anchor_message: anchor_message).send(:control_fence)
  end

  def self.current?(reminder:, conversation:, assistant:, anchor_message:, message: nil)
    new(
      reminder: reminder,
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor_message,
      message: message
    ).current?
  rescue Captain::Conversation::ControlGenerationStaleError, ActiveRecord::RecordNotFound
    false
  end

  def initialize(reminder:, conversation:, assistant:, anchor_message:, message: nil)
    @reminder = reminder
    @conversation = conversation
    @assistant = assistant
    @anchor_message = anchor_message
    @message = message
  end

  def current?
    return false unless records_current?
    return false unless run_fence_current?

    !cancellation_state_matches?
  rescue Captain::Conversation::ControlGenerationStaleError, ActiveRecord::RecordNotFound
    false
  end

  private

  attr_reader :reminder, :conversation, :assistant, :anchor_message, :message

  def records_current?
    records_match? && conversation.pending? && assistant_feature_enabled? &&
      follow_up_settings_current? && !legacy_conversation_plan_pending?
  end

  def records_match?
    reminder_matches_conversation? && assistant_matches_conversation? &&
      anchor_matches_conversation? && message_matches?
  end

  def reminder_matches_conversation?
    reminder.captain_follow_up? && conversation.present? &&
      reminder.account_id == conversation.account_id &&
      reminder.conversation_id == conversation.id &&
      reminder.target_conversation_id == conversation.id
  end

  def assistant_matches_conversation?
    assistant.present? && assistant_tenant_matches? && assistant_controls_inbox?
  end

  def assistant_tenant_matches?
    assistant.account_id == reminder.account_id && assistant.external_agent?
  end

  def assistant_controls_inbox?
    conversation.inbox_id.present? &&
      assistant.inboxes.exists?(id: conversation.inbox_id) &&
      conversation.inbox&.captain_assistant&.id == assistant.id
  end

  def anchor_matches_conversation?
    anchor_message.present? && anchor_tenant_matches? &&
      anchor_authored_by_assistant? && eligible_anchor?
  end

  def anchor_tenant_matches?
    anchor_message.account_id == conversation.account_id &&
      anchor_message.conversation_id == conversation.id &&
      anchor_message.inbox_id == conversation.inbox_id
  end

  def anchor_authored_by_assistant?
    anchor_message.outgoing? && !anchor_message.private? && !anchor_message.failed? &&
      anchor_message.sender_type == assistant.class.name && anchor_message.sender_id == assistant.id
  end

  def eligible_anchor?
    Captain::Conversation::FollowUpJob.eligible_anchor_message?(anchor_message: anchor_message, assistant: assistant)
  end

  def message_matches?
    return true if message.blank?

    message_owner_matches? && message_marker_matches?
  end

  def message_owner_matches?
    message.account_id == reminder.account_id &&
      message.conversation_id == conversation.id &&
      message.inbox_id == conversation.inbox_id &&
      message_authored_by_assistant?
  end

  def message_authored_by_assistant?
    message.sender_type == assistant.class.name && message.sender_id == assistant.id &&
      message.outgoing? && !message.private? && !message.failed?
  end

  def message_marker_matches?
    attributes = message.additional_attributes.to_h.deep_stringify_keys
    marker = attributes['captain_follow_up'].to_h
    follow_up = follow_up_metadata

    attributes['touch_id'].to_s == reminder.id.to_s &&
      marker['assistant_id'].to_i == assistant.id &&
      marker['anchor_message_id'].to_i == anchor_message.id &&
      marker['step_index'].to_i == follow_up['step_index'].to_i
  end

  def assistant_feature_enabled?
    assistant.account.feature_enabled?('captain_integration')
  end

  def follow_up_settings_current?
    settings = assistant.config.to_h.deep_stringify_keys['follow_up_settings'].to_h
    settings['enabled'] == true && configured_step?(settings)
  end

  def configured_step?(settings)
    step = configured_follow_up_step(settings)
    return false unless step

    return step['message'].to_s.strip.present? if static_step?(step)

    settings['prompt'].to_s.strip.present? && step['objective'].to_s.strip.present?
  end

  def configured_follow_up_step(settings)
    step = Array(settings['steps'])[follow_up_metadata['step_index'].to_i]
    step.deep_stringify_keys if step.is_a?(Hash)
  end

  def static_step?(step)
    step['mode'].to_s == 'static' || (step['mode'].blank? && step['message'].to_s.strip.present?)
  end

  def legacy_conversation_plan_pending?
    conversation.account.reminders.active_delivery_or_open
                .where.not(reminder_group_id: nil)
                .exists?([
                           'conversation_id = :conversation_id OR target_conversation_id = :conversation_id',
                           { conversation_id: conversation.id }
                         ])
  end

  def run_fence_current?
    fence = control_fence
    return false unless valid_control_fence?(fence)

    Captain::Conversation::RunFenceService.new(
      assistant: assistant,
      state: {
        account_id: conversation.account_id,
        assistant_id: assistant.id,
        conversation: { id: conversation.id },
        captain_response_fence: fence
      },
      stage: 'follow_up_delivery'
    ).ensure_current!
    true
  end

  def cancellation_state_matches?
    fence = control_fence
    Captain::Conversation::ResponseCancellationService.new(
      conversation: conversation,
      assistant: assistant
    ).cancelled?(
      expected_control_generation: fence['control_generation'],
      expected_status_transition_id: fence['status_transition_id'],
      expected_last_message_id: fence['last_message_id']
    )
  end

  def control_fence
    @control_fence ||= Captain::Conversation::FollowUpControlFence.resolve(
      reminder: reminder,
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor_message
    )
  end

  def valid_control_fence?(fence)
    fence.respond_to?(:key?) && CONTROL_FENCE_KEYS.all? { |key| fence.key?(key) && fence[key].present? }
  end

  def follow_up_metadata
    reminder.metadata.to_h.deep_stringify_keys.fetch('captain_follow_up', {}).to_h
  end
end
