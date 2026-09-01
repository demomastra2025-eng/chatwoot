# frozen_string_literal: true

class CommunicationThreads::ChannelReplyCapabilityBuilder
  REPLY_WINDOW_OPEN_UNSET = Object.new.freeze

  def self.linked(conversation:, inbox:, policy:, reply_window_open: REPLY_WINDOW_OPEN_UNSET, voice_call_allowed: false)
    new(
      conversation: conversation,
      inbox: inbox,
      policy: policy,
      reply_window_open: reply_window_open,
      voice_call_allowed: voice_call_allowed
    ).linked
  end

  def self.unlinked(inbox:, policy:, target_error:, voice_call_allowed: false)
    new(inbox: inbox, policy: policy, target_error: target_error, voice_call_allowed: voice_call_allowed).unlinked
  end

  def initialize(inbox:, policy:, conversation: nil, **options)
    @inbox = inbox
    @policy = policy
    @conversation = conversation
    @target_error = options[:target_error]
    @provided_reply_window_open = options.fetch(:reply_window_open, REPLY_WINDOW_OPEN_UNSET)
    @voice_call_allowed = options.fetch(:voice_call_allowed, false)
  end

  def linked
    return voice_capability_payload_for if voice_channel?

    can_send_text = linked_reply_window_open? && free_text_allowed?
    capability_payload(
      can_send_text: can_send_text,
      reply_window_open: linked_reply_window_open?,
      disabled_reason: disabled_reason(linked_reply_window_open?),
      can_call: whatsapp_call_enabled?
    )
  end

  def unlinked
    return voice_capability_payload_for(target_error) if voice_channel?

    reply_window_open = unlinked_reply_window_open?
    can_send_text = target_error.blank? && free_text_allowed?
    capability_payload(
      can_send_text: can_send_text,
      reply_window_open: reply_window_open,
      disabled_reason: target_error || disabled_reason(reply_window_open)
    )
  end

  private

  attr_reader :conversation, :inbox, :policy, :target_error, :provided_reply_window_open, :voice_call_allowed

  def voice_capability_payload_for(target_reason = nil)
    allowed = voice_call_allowed && target_reason.blank?
    voice_capability_payload(
      target_reason || ('call_not_permitted' unless allowed),
      can_reply: allowed,
      can_call: allowed
    )
  end

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
      requires_template: policy.requires_template,
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

  def channel_template_supported?
    Array(policy.allowed_content_kinds).include?('channel_template')
  end

  def reauthorization_required?
    inbox.channel.respond_to?(:reauthorization_required?) && inbox.channel.reauthorization_required?
  end
end
