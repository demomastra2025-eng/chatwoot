# frozen_string_literal: true

class CommunicationThreads::ChannelPayloadBuilder
  def self.perform(payload)
    new(payload).perform
  end

  def initialize(payload)
    @payload = payload
  end

  def perform
    base_channel_payload.merge(
      delivery_channel_payload,
      reply_state_payload
    )
  end

  private

  attr_reader :payload

  def base_channel_payload
    channel_identity_payload.merge(channel_state_payload)
  end

  def channel_identity_payload
    {
      conversation_id: conversation_id,
      inbox_id: inbox.id,
      inbox_name: inbox.name,
      source_id: contact_inbox&.source_id,
      contact_inbox_id: payload[:contact_inbox_id],
      channel_profile: contact_inbox&.channel_profile&.push_event_data,
      channel: inbox.try(:channel_type),
      medium: channel_medium
    }
  end

  def channel_state_payload
    {
      status: payload[:status],
      primary: payload[:primary],
      last_activity_at: payload[:last_activity_at],
      media_server_enabled: media_server_enabled?,
      channel_key: channel_key
    }
  end

  def delivery_channel_payload
    {
      provider: policy.provider,
      allowed_content_kinds: policy.allowed_content_kinds,
      delivery_mode: policy.delivery_mode,
      delivery_policy: policy.as_json
    }
  end

  def reply_state_payload
    disabled_reason = payload[:disabled_reason]

    {
      can_reply: payload[:can_reply],
      can_send_text: payload[:can_send_text],
      can_send_attachments: payload[:can_send_attachments],
      can_call: payload[:can_call],
      requires_template: payload[:requires_template],
      reply_window_open: payload[:reply_window_open],
      reply_window_closes_at: payload[:reply_window_closes_at]&.iso8601,
      reauthorization_required: payload[:reauthorization_required],
      disabled: disabled_reason.present? && disabled_reason != 'template_required',
      disabled_reason: disabled_reason
    }
  end

  def inbox
    @inbox ||= payload.fetch(:inbox)
  end

  def contact_inbox
    payload[:contact_inbox]
  end

  def policy
    payload.fetch(:policy)
  end

  def conversation_id
    payload[:conversation_id]
  end

  def media_server_enabled?
    return false unless inbox.try(:channel_type) == 'Channel::Whatsapp'

    defined?(Call) ? Call.media_server_enabled?(inbox: inbox) : false
  end

  def channel_medium
    inbox.channel.respond_to?(:medium) ? inbox.channel.medium : nil
  end

  def channel_key
    conversation_id.present? ? "conversation:#{conversation_id}" : "inbox:#{inbox.id}"
  end
end
