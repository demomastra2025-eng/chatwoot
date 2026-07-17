# frozen_string_literal: true

class CommunicationThreads::ChannelCapabilitiesBuilder
  CONTACT_TARGET_REQUIREMENTS = {
    'Channel::Email' => [:email],
    'Channel::Sms' => [:phone_number],
    'Channel::TwilioSms' => [:phone_number],
    'Channel::Voice' => [:phone_number],
    'Channel::Whatsapp' => [:phone_number]
  }.freeze

  SUPPORTED_UNLINKED_CHANNELS = (CONTACT_TARGET_REQUIREMENTS.keys + Inbox::API_CHANNEL_TYPES + ['Channel::WebWidget']).freeze
  INITIALIZE_OPTION_KEYS = %i[
    contact available_inboxes include_unlinked deduplicate_linked preferred_status
    unread_counts last_incoming_message_timestamps
  ].freeze

  def initialize(links:, **options)
    validate_options!(options)
    @links = Array(links)
    @contact = options.fetch(:contact, nil) || @links.first&.communication_thread&.contact
    @available_inboxes = Array(options.fetch(:available_inboxes, []))
    @include_unlinked = options.fetch(:include_unlinked, false)
    @deduplicate_linked = options.fetch(:deduplicate_linked, true)
    @preferred_status = options.fetch(:preferred_status, nil).to_s.presence
    @unread_counts = options[:unread_counts]
    @last_incoming_message_timestamps = options[:last_incoming_message_timestamps]
  end

  def perform
    linked_channels + (include_unlinked ? unlinked_channels : [])
  end

  private

  attr_reader :links, :contact, :available_inboxes, :include_unlinked, :deduplicate_linked, :preferred_status,
              :unread_counts, :last_incoming_message_timestamps

  def validate_options!(options)
    unknown_options = options.keys - INITIALIZE_OPTION_KEYS
    return if unknown_options.empty?

    raise ArgumentError, "Unknown channel capability options: #{unknown_options.join(', ')}"
  end

  def linked_channels
    selected_links = deduplicate_linked ? deduplicated_links : links
    selected_links.map { |link| build_linked_channel(link) }
  end

  def deduplicated_links
    links.group_by(&:inbox_id).values.map do |grouped_links|
      grouped_links.max_by { |link| linked_channel_sort_key(link) }
    end
  end

  def linked_channel_sort_key(link)
    conversation = link.conversation
    policy = delivery_policy(conversation: conversation, inbox: link.inbox)
    [
      preferred_status.present? && conversation&.status == preferred_status ? 1 : 0,
      linked_reply_window_open(conversation, policy) ? 1 : 0,
      conversation&.open? ? 1 : 0,
      conversation&.last_activity_at.to_i,
      conversation&.id.to_i
    ]
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
    reply_window_open = linked_reply_window_open(conversation, policy)
    capabilities = CommunicationThreads::ChannelReplyCapabilityBuilder.linked(
      conversation: conversation,
      inbox: inbox,
      policy: policy,
      reply_window_open: reply_window_open
    )

    channel_payload({
      conversation_id: conversation.display_id,
      inbox: inbox,
      contact_inbox: link.contact_inbox,
      contact_inbox_id: link.contact_inbox_id,
      status: conversation.status,
      primary: link.primary?,
      last_activity_at: conversation.last_activity_at.to_i
    }.merge(read_state_payload(conversation), capabilities))
  end

  def read_state_payload(conversation)
    {
      agent_last_seen_at: conversation.agent_last_seen_at&.to_i,
      assignee_last_seen_at: conversation.assignee_last_seen_at&.to_i,
      unread_count: conversation_unread_count(conversation)
    }
  end

  def build_unlinked_channel(inbox)
    contact_inbox = contact_inbox_by_inbox_id[inbox.id]
    target_error = contact_target_error(inbox)
    policy = delivery_policy(conversation: nil, inbox: inbox)
    capabilities = CommunicationThreads::ChannelReplyCapabilityBuilder.unlinked(
      inbox: inbox,
      policy: policy,
      target_error: target_error
    )

    channel_payload({
      conversation_id: nil,
      inbox: inbox,
      contact_inbox: contact_inbox,
      contact_inbox_id: contact_inbox&.id,
      status: nil,
      primary: false,
      last_activity_at: nil
    }.merge(capabilities))
  end

  def channel_payload(payload)
    CommunicationThreads::ChannelPayloadBuilder.perform(payload)
  end

  def contact_target_error(inbox)
    return 'unsupported_channel' unless SUPPORTED_UNLINKED_CHANNELS.include?(inbox.channel_type)

    Array(CONTACT_TARGET_REQUIREMENTS[inbox.channel_type]).each do |attribute|
      return "missing_contact_#{attribute}" if contact.blank? || contact.public_send(attribute).blank?
    end

    nil
  end

  def delivery_policy(conversation:, inbox:)
    @delivery_policies ||= {}
    cache_key = [conversation&.id, inbox.id]
    return @delivery_policies[cache_key] if @delivery_policies.key?(cache_key)

    options = {
      conversation: conversation,
      inbox: inbox,
      content_kind: 'free_text'
    }
    if conversation.present? && !last_incoming_message_timestamps.nil?
      options[:last_incoming_message_at] = last_incoming_message_timestamps[conversation.id]
    end

    @delivery_policies[cache_key] = Outbound::DeliveryPolicy.evaluate(**options)
  end

  def linked_reply_window_open(conversation, policy)
    @linked_reply_window_states ||= {}
    return @linked_reply_window_states[conversation.id] if @linked_reply_window_states.key?(conversation.id)

    @linked_reply_window_states[conversation.id] = calculate_linked_reply_window_open(conversation, policy)
  end

  def calculate_linked_reply_window_open(conversation, policy)
    return policy.reply_window_open unless policy.reply_window_open.nil?
    return conversation.can_reply? if last_incoming_message_timestamps.nil?

    Conversations::MessageWindowService.new(
      conversation,
      last_incoming_message_at: last_incoming_message_timestamps[conversation.id]
    ).can_reply?
  end

  def conversation_unread_count(conversation)
    return conversation.unread_incoming_messages_count if unread_counts.nil?

    unread_counts.fetch(conversation.id, 0)
  end

  def contact_inbox_by_inbox_id
    @contact_inbox_by_inbox_id ||= if contact.blank?
                                     {}
                                   else
                                     ContactInbox.includes(:channel_profile).where(
                                       contact_id: contact.id,
                                       inbox_id: available_inboxes.map(&:id)
                                     ).index_by(&:inbox_id)
                                   end
  end
end
