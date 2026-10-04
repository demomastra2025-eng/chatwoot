# frozen_string_literal: true

class Captain::Conversation::FollowUpControlFence
  KEYS = %w[control_generation status_transition_id last_message_id].freeze

  def self.resolve(reminder:, conversation:, assistant:, anchor_message:)
    new(
      reminder: reminder,
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor_message
    ).resolve
  end

  def initialize(reminder:, conversation:, assistant:, anchor_message:)
    @reminder = reminder
    @conversation = conversation
    @assistant = assistant
    @anchor_message = anchor_message
  end

  def resolve
    return stored_fence if valid_fence?(stored_fence)

    legacy_fence
  end

  private

  attr_reader :reminder, :conversation, :assistant, :anchor_message

  def stored_fence
    @stored_fence ||= reminder.metadata.to_h.deep_stringify_keys
                              .fetch('captain_follow_up', {}).to_h
                              .fetch('control_fence', {}).to_h.deep_stringify_keys
  end

  def legacy_fence
    return unless legacy_records_match?

    incoming = prior_incoming_message
    return unless incoming

    build_fence(incoming)
  end

  def legacy_records_match?
    reminder_matches_conversation? && assistant_matches_conversation? && legacy_anchor_matches?
  end

  def reminder_matches_conversation?
    reminder.captain_follow_up? && reminder.account_id == conversation.account_id &&
      reminder.conversation_id == conversation.id && reminder.target_conversation_id == conversation.id
  end

  def assistant_matches_conversation?
    assistant.present? && assistant.account_id == conversation.account_id && assistant.external_agent? &&
      assistant.inboxes.exists?(id: conversation.inbox_id) &&
      conversation.inbox&.captain_assistant&.id == assistant.id
  end

  def legacy_anchor_matches?
    conversation.pending? && anchor_belongs_to_conversation? &&
      anchor_publicly_authored_by_assistant? && eligible_anchor?
  end

  def anchor_belongs_to_conversation?
    anchor_message.present? && anchor_message.account_id == conversation.account_id &&
      anchor_message.conversation_id == conversation.id && anchor_message.inbox_id == conversation.inbox_id
  end

  def anchor_publicly_authored_by_assistant?
    anchor_message.sender_type == assistant.class.name && anchor_message.sender_id == assistant.id &&
      anchor_message.outgoing? && !anchor_message.private? && !anchor_message.failed?
  end

  def eligible_anchor?
    Captain::Conversation::FollowUpJob.eligible_anchor_message?(anchor_message: anchor_message, assistant: assistant)
  end

  def prior_incoming_message
    Captain::Conversation::ControlService.messages_scope(conversation).incoming
                                         .where('messages.id < ?', anchor_message.id)
                                         .order(id: :desc).first
  end

  def build_fence(incoming)
    generation = legacy_generation(incoming)
    status_epoch = legacy_status_epoch(incoming)
    return unless generation == conversation.current_captain_control_generation.to_i
    return unless status_epoch == conversation.status_transitions.maximum(:id).to_i

    {
      'control_generation' => generation,
      'status_transition_id' => status_epoch,
      'last_message_id' => incoming.id
    }
  end

  def legacy_generation(incoming)
    stamped = anchor_attributes['captain_control_generation'].presence ||
              incoming_attributes(incoming)['captain_control_generation']
    return stamped.to_i if stamped.present?

    generation = conversation.current_captain_control_generation.to_i
    generation.zero? ? generation : nil
  end

  def legacy_status_epoch(incoming)
    stamped = anchor_attributes['captain_status_transition_id'].presence ||
              incoming_attributes(incoming)['captain_status_transition_id']
    return stamped.to_i if stamped.present?

    ConversationStatusTransition.where(
      account_id: conversation.account_id,
      conversation_id: conversation.id
    ).where('created_at <= ?', anchor_message.created_at).maximum(:id).to_i
  end

  def anchor_attributes
    @anchor_attributes ||= anchor_message.additional_attributes.to_h.deep_stringify_keys
  end

  def incoming_attributes(incoming)
    incoming.additional_attributes.to_h.deep_stringify_keys
  end

  def valid_fence?(fence)
    fence.respond_to?(:key?) && KEYS.all? { |key| fence.key?(key) && fence[key].present? }
  end
end
