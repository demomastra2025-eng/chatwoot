# frozen_string_literal: true

class CommunicationThreads::ChannelCapabilitiesBuilder
  CONTACT_TARGET_REQUIREMENTS = {
    'Channel::Email' => [:email],
    'Channel::Sms' => [:phone_number],
    'Channel::TwilioSms' => [:phone_number],
    'Channel::Whatsapp' => [:phone_number]
  }.freeze

  SUPPORTED_UNLINKED_CHANNELS = (CONTACT_TARGET_REQUIREMENTS.keys + Inbox::API_CHANNEL_TYPES + ['Channel::WebWidget']).freeze

  def initialize(links:, contact: nil, available_inboxes: [])
    @links = Array(links)
    @contact = contact || @links.first&.communication_thread&.contact
    @available_inboxes = Array(available_inboxes)
  end

  def perform
    linked_channels + unlinked_channels
  end

  private

  attr_reader :links, :contact, :available_inboxes

  def linked_channels
    links.map { |link| build_linked_channel(link) }
  end

  def unlinked_channels
    linked_inbox_ids = links.map(&:inbox_id)
    available_inboxes.reject { |inbox| linked_inbox_ids.include?(inbox.id) }
                     .map { |inbox| build_unlinked_channel(inbox) }
  end

  def build_linked_channel(link)
    conversation = link.conversation
    inbox = link.inbox
    policy = delivery_policy(conversation: conversation, inbox: inbox)

    channel_payload({
      conversation_id: conversation.display_id,
      inbox: inbox,
      contact_inbox_id: link.contact_inbox_id,
      status: conversation.status,
      primary: link.primary?,
      last_activity_at: conversation.last_activity_at.to_i
    }.merge(linked_capability(conversation: conversation, inbox: inbox, policy: policy)))
  end

  def build_unlinked_channel(inbox)
    target_error = contact_target_error(inbox)
    policy = delivery_policy(conversation: nil, inbox: inbox)

    channel_payload({
      conversation_id: nil,
      inbox: inbox,
      contact_inbox_id: contact_inbox_by_inbox_id[inbox.id]&.id,
      status: nil,
      primary: false,
      last_activity_at: nil
    }.merge(unlinked_capability(inbox: inbox, policy: policy, target_error: target_error)))
  end

  def linked_capability(conversation:, inbox:, policy:)
    reply_window_open = policy.reply_window_open.nil? ? conversation.can_reply? : policy.reply_window_open
    reauthorization_required = reauthorization_required?(inbox)
    can_send_text = reply_window_open && free_text_allowed?(policy, reauthorization_required)
    disabled_reason = linked_disabled_reason(
      reply_window_open: reply_window_open,
      template_required: policy.requires_template,
      reauthorization_required: reauthorization_required,
      policy: policy
    )

    capability_payload(policy, can_send_text, reply_window_open, reauthorization_required, disabled_reason)
  end

  def unlinked_capability(inbox:, policy:, target_error:)
    reply_window_open = policy.reply_window_open.nil? ? policy.allowed? : policy.reply_window_open
    reauthorization_required = reauthorization_required?(inbox)
    can_send_text = target_error.blank? && free_text_allowed?(policy, reauthorization_required)
    disabled_reason = target_error || linked_disabled_reason(
      reply_window_open: reply_window_open,
      template_required: policy.requires_template,
      reauthorization_required: reauthorization_required,
      policy: policy
    )

    capability_payload(policy, can_send_text, reply_window_open, reauthorization_required, disabled_reason)
  end

  def capability_payload(policy, can_send_text, reply_window_open, reauthorization_required, disabled_reason)
    {
      can_reply: can_send_text,
      can_send_text: can_send_text,
      can_send_attachments: can_send_text,
      requires_template: policy.requires_template,
      reply_window_open: reply_window_open,
      reply_window_closes_at: policy.reply_window_closes_at,
      reauthorization_required: reauthorization_required,
      disabled_reason: disabled_reason,
      policy: policy
    }
  end

  def channel_payload(payload)
    base_channel_payload(payload).merge(
      delivery_channel_payload(payload),
      reply_state_payload(payload)
    )
  end

  def base_channel_payload(payload)
    inbox = payload.fetch(:inbox)
    conversation_id = payload[:conversation_id]

    {
      conversation_id: conversation_id,
      inbox_id: inbox.id,
      inbox_name: inbox.name,
      contact_inbox_id: payload[:contact_inbox_id],
      channel: inbox.try(:channel_type),
      medium: inbox.channel.respond_to?(:medium) ? inbox.channel.medium : nil,
      status: payload[:status],
      primary: payload[:primary],
      last_activity_at: payload[:last_activity_at],
      channel_key: channel_key(conversation_id, inbox.id)
    }
  end

  def delivery_channel_payload(payload)
    policy = payload.fetch(:policy)

    {
      provider: policy.provider,
      allowed_content_kinds: policy.allowed_content_kinds,
      delivery_mode: policy.delivery_mode,
      delivery_policy: policy.as_json
    }
  end

  def reply_state_payload(payload)
    disabled_reason = payload[:disabled_reason]

    {
      can_reply: payload[:can_reply],
      can_send_text: payload[:can_send_text],
      can_send_attachments: payload[:can_send_attachments],
      requires_template: payload[:requires_template],
      reply_window_open: payload[:reply_window_open],
      reply_window_closes_at: payload[:reply_window_closes_at]&.iso8601,
      reauthorization_required: payload[:reauthorization_required],
      disabled: disabled_reason.present? && disabled_reason != 'template_required',
      disabled_reason: disabled_reason
    }
  end

  def linked_disabled_reason(reply_window_open:, template_required:, reauthorization_required:, policy:)
    return 'reauthorization_required' if reauthorization_required
    return 'template_required' if template_required
    return policy.reason if policy.reason.present?
    return 'not_replyable' unless reply_window_open || channel_template_supported?(policy)
  end

  def contact_target_error(inbox)
    return 'unsupported_channel' unless SUPPORTED_UNLINKED_CHANNELS.include?(inbox.channel_type)

    Array(CONTACT_TARGET_REQUIREMENTS[inbox.channel_type]).each do |attribute|
      return "missing_contact_#{attribute}" if contact.blank? || contact.public_send(attribute).blank?
    end

    nil
  end

  def delivery_policy(conversation:, inbox:)
    Outbound::DeliveryPolicy.evaluate(
      conversation: conversation,
      inbox: inbox,
      content_kind: 'free_text'
    )
  end

  def free_text_allowed?(policy, reauthorization_required)
    policy.allowed? && policy.delivery_mode == 'free_text' && !reauthorization_required
  end

  def channel_template_supported?(policy)
    Array(policy.allowed_content_kinds).include?('channel_template')
  end

  def reauthorization_required?(inbox)
    inbox.channel.respond_to?(:reauthorization_required?) && inbox.channel.reauthorization_required?
  end

  def contact_inbox_by_inbox_id
    @contact_inbox_by_inbox_id ||= if contact.blank?
                                     {}
                                   else
                                     ContactInbox.where(
                                       contact_id: contact.id,
                                       inbox_id: available_inboxes.map(&:id)
                                     ).index_by(&:inbox_id)
                                   end
  end

  def channel_key(conversation_id, inbox_id)
    conversation_id.present? ? "conversation:#{conversation_id}" : "inbox:#{inbox_id}"
  end
end
