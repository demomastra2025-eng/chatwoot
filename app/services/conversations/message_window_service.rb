# Whether an agent may still write to the customer in this channel. The window belongs to the customer in the inbox (one number
# in the inbox of WhatsApp), not to one conversation: it is opened by the last incoming message of the same contact in any
# conversation of the same inbox. A conversation that staff started from a card or a calendar entry, or that follows a resolved
# one, is as open as the customer's last message makes it. Outbound::DeliveryPolicy reads the same messages.
class Conversations::MessageWindowService
  LAST_INCOMING_MESSAGE_AT_UNSET = Object.new.freeze
  MESSAGING_WINDOW_24_HOURS = 24.hours
  MESSAGING_WINDOW_7_DAYS = 7.days

  # The incoming messages of one customer in one inbox, in all the conversations they have there.
  def self.incoming_messages(account_id:, contact_id:, inbox_id:)
    Message.incoming.joins(:conversation).where(
      account_id: account_id,
      conversations: { account_id: account_id, contact_id: contact_id, inbox_id: inbox_id }
    )
  end

  # { conversation id => time of the last incoming message of the customer in the inbox of that conversation }, for the
  # conversations that have one. One query for any number of conversations (the lists need it for a whole page).
  def self.last_incoming_timestamps(conversations)
    Array(conversations).group_by(&:account_id).each_with_object({}) do |(account_id, group), result|
      latest = latest_by_customer(account_id, group)
      group.each do |conversation|
        timestamp = latest[[conversation.contact_id, conversation.inbox_id]]
        result[conversation.id] = timestamp if timestamp
      end
    end
  end

  def self.latest_by_customer(account_id, conversations)
    return {} if conversations.empty?

    Message.incoming.reorder(nil).joins(:conversation)
           .where(account_id: account_id, conversations: { account_id: account_id, contact_id: conversations.map(&:contact_id).uniq,
                                                           inbox_id: conversations.map(&:inbox_id).uniq })
           .group('conversations.contact_id', 'conversations.inbox_id')
           .maximum('messages.created_at')
  end
  private_class_method :latest_by_customer

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

  def last_incoming_message_at
    return @provided_last_incoming_message_at unless @provided_last_incoming_message_at.equal?(LAST_INCOMING_MESSAGE_AT_UNSET)

    @last_incoming_message_at ||= self.class.last_incoming_timestamps([@conversation])[@conversation.id]
  end
end
