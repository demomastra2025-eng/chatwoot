# frozen_string_literal: true

class CommunicationThreads::ChannelReplyCapabilityBuilder
  REPLY_WINDOW_OPEN_UNSET = Object.new.freeze

  def self.linked(conversation:, inbox:, policy:, reply_window_open: REPLY_WINDOW_OPEN_UNSET)
    new(conversation: conversation, inbox: inbox, policy: policy, reply_window_open: reply_window_open).linked
  end

  def self.unlinked(inbox:, policy:, target_error:)
    new(inbox: inbox, policy: policy, target_error: target_error).unlinked
  end

  def initialize(inbox:, policy:, conversation: nil, target_error: nil, reply_window_open: REPLY_WINDOW_OPEN_UNSET)
    @inbox = inbox
    @policy = policy
    @conversation = conversation
    @target_error = target_error
    @provided_reply_window_open = reply_window_open
  end

  def linked
    return voice_capability_payload if voice_channel?

    can_send_text = linked_reply_window_open? && free_text_allowed?
    capability_payload(
      can_send_text: can_send_text,
      reply_window_open: linked_reply_window_open?,
      disabled_reason: disabled_reason(linked_reply_window_open?),
      can_call: whatsapp_call_enabled? || telegram_personal_call_enabled?
    )
  end

  def unlinked
    return voice_capability_payload(target_error, can_reply: target_error.blank?, can_call: target_error.blank?) if voice_channel?

    reply_window_open = unlinked_reply_window_open?
    reachable = target_error.blank?
    capability_payload(
      can_send_text: reachable && free_text_allowed?,
      reply_window_open: reply_window_open,
      # A template cannot reach a person the channel has no number or address for: the channel asks for nothing then, it only
      # says why it is disabled (the screen offers to write to the holder of a shared number, or to add the number to the card).
      requires_template: reachable && policy.requires_template,
      disabled_reason: target_error || disabled_reason(reply_window_open)
    )
  end

  private

  attr_reader :conversation, :inbox, :policy, :target_error, :provided_reply_window_open

  def voice_capability_payload(disabled_reason = nil, can_reply: true, can_call: true)
    capability_payload(
      can_send_text: false,
      reply_window_open: true,
      disabled_reason: disabled_reason,
      can_reply: can_reply,
      can_call: can_call
    )
  end

  def capability_payload(attributes)
    can_send_text = attributes.fetch(:can_send_text)

    {
      can_reply: attributes.fetch(:can_reply, can_send_text),
      can_send_text: can_send_text,
      can_send_attachments: can_send_text,
      can_call: attributes.fetch(:can_call, false),
      requires_template: attributes.fetch(:requires_template, policy.requires_template),
      reply_window_open: attributes.fetch(:reply_window_open),
      reply_window_closes_at: policy.reply_window_closes_at,
      reauthorization_required: reauthorization_required?,
      disabled_reason: attributes.fetch(:disabled_reason),
      policy: policy
    }
  end

  def linked_reply_window_open?
    return provided_reply_window_open unless provided_reply_window_open.equal?(REPLY_WINDOW_OPEN_UNSET)

    policy.reply_window_open.nil? ? conversation.can_reply? : policy.reply_window_open
  end

  def unlinked_reply_window_open?
    policy.reply_window_open.nil? ? policy.allowed? : policy.reply_window_open
  end

  def disabled_reason(reply_window_open)
    return 'template_required' if policy.requires_template
    return policy.reason if policy.reason.present?
    return 'not_replyable' unless reply_window_open || channel_template_supported?
  end

  def free_text_allowed?
    policy.allowed? && policy.delivery_mode == 'free_text'
  end

  def voice_channel?
    inbox.try(:channel_type) == 'Channel::Voice'
  end

  def whatsapp_call_enabled?
    inbox.try(:channel_type) == 'Channel::Whatsapp' &&
      inbox.channel.respond_to?(:voice_enabled?) &&
      inbox.channel.voice_enabled?
  end

  def telegram_personal_call_enabled?
    inbox.try(:channel_type) == 'Channel::TelegramPersonal' &&
      inbox.channel.respond_to?(:voice_enabled?) &&
      inbox.channel.voice_enabled? &&
      !telegram_group_conversation?
  end

  def telegram_group_conversation?
    chat_type = conversation&.additional_attributes&.dig('chat_type').to_s
    return true if %w[group supergroup channel].include?(chat_type)

    source_id = conversation&.contact_inbox&.source_id.to_s
    source_id.start_with?('-')
  end

  def channel_template_supported?
    Array(policy.allowed_content_kinds).include?('channel_template')
  end

  def reauthorization_required?
    inbox.channel.respond_to?(:reauthorization_required?) && inbox.channel.reauthorization_required?
  end
end
