class Conversations::MessageWindowService
  LAST_INCOMING_MESSAGE_AT_UNSET = Object.new.freeze
  MESSAGING_WINDOW_24_HOURS = 24.hours
  MESSAGING_WINDOW_7_DAYS = 7.days

  def initialize(conversation, last_incoming_message_at: LAST_INCOMING_MESSAGE_AT_UNSET)
    @conversation = conversation
    @provided_last_incoming_message_at = last_incoming_message_at
  end

  def can_reply?
    return true if messaging_window.blank?

    last_message_in_messaging_window?(messaging_window)
  end

  private

  def messaging_window
    case @conversation.inbox.channel_type
    when *Inbox::API_CHANNEL_TYPES
      api_messaging_window
    when 'Channel::FacebookPage'
      messenger_messaging_window
    when 'Channel::Instagram'
      instagram_messaging_window
    when 'Channel::Tiktok'
      tiktok_messaging_window
    when 'Channel::Whatsapp'
      MESSAGING_WINDOW_24_HOURS
    when 'Channel::TwilioSms'
      twilio_messaging_window
    end
  end

  def last_message_in_messaging_window?(time)
    return false if last_incoming_message_at.nil?

    Time.current < last_incoming_message_at + time
  end

  def api_messaging_window
    return if @conversation.inbox.channel.additional_attributes['agent_reply_time_window'].blank?

    @conversation.inbox.channel.additional_attributes['agent_reply_time_window'].to_i.hours
  end

  # Check medium of the inbox to determine the messaging window
  def twilio_messaging_window
    @conversation.inbox.channel.medium == 'whatsapp' ? MESSAGING_WINDOW_24_HOURS : nil
  end

  def messenger_messaging_window
    meta_messaging_window('ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT')
  end

  def instagram_messaging_window
    meta_messaging_window('ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT')
  end

  def tiktok_messaging_window
    48.hours
  end

  def meta_messaging_window(config_key)
    GlobalConfigService.load(config_key, nil) ? MESSAGING_WINDOW_7_DAYS : MESSAGING_WINDOW_24_HOURS
  end

  def last_incoming_message
    @last_incoming_message ||= @conversation.messages.where(account_id: @conversation.account_id).incoming&.last
  end

  def last_incoming_message_at
    return @provided_last_incoming_message_at unless @provided_last_incoming_message_at.equal?(LAST_INCOMING_MESSAGE_AT_UNSET)

    last_incoming_message&.created_at
  end
end
