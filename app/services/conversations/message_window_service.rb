# Whether an agent may still write to the customer in this channel. The window belongs to the customer, not to one conversation:
# it is opened by the last incoming message of the customer in any conversation of the inbox. A conversation that staff started
# from a card or a calendar entry, or that follows a resolved one, is as open as the customer's last message makes it.
#
# The customer is a WhatsApp user, who is known to us by more than one identity in the inbox (the phone number and the business
# scoped user ids, one contact_inbox each, see Whatsapp::IdentifierSyncService), so the identities of one contact in one inbox
# are one customer. The exception is a contact with two different phone numbers in the inbox: they are two customers, each with
# a window of its own, and a message from one number does not open the other. Outbound::DeliveryPolicy reads the same messages.
class Conversations::MessageWindowService
  LAST_INCOMING_MESSAGE_AT_UNSET = Object.new.freeze
  MESSAGING_WINDOW_24_HOURS = 24.hours
  MESSAGING_WINDOW_7_DAYS = 7.days

  # The incoming messages of one customer: those of the given contact_inboxes (see .customer_ids), in all their conversations.
  def self.incoming_messages(account_id:, contact_inbox_ids:)
    Message.incoming.joins(:conversation).where(
      account_id: account_id,
      conversations: { account_id: account_id, contact_inbox_id: contact_inbox_ids }
    )
  end

  # { conversation id => time of the last incoming message of the customer of that conversation }, for the conversations that have
  # one. Two queries for any number of conversations (the lists need it for a whole page).
  def self.last_incoming_timestamps(conversations)
    Array(conversations).group_by(&:account_id).each_with_object({}) do |(account_id, group), result|
      customers = customers_of(group)
      latest = latest_by_contact_inbox(account_id: account_id, contact_inbox_ids: customers.values.flatten)
      group.each do |conversation|
        timestamp = customers[conversation.id].filter_map { |id| latest[id] }.max
        result[conversation.id] = timestamp if timestamp
      end
    end
  end

  # { contact_inbox id => time of its last incoming message }, for the contact_inboxes that have one
  def self.latest_by_contact_inbox(account_id:, contact_inbox_ids:)
    ids = Array(contact_inbox_ids).compact.uniq
    return {} if ids.empty?

    Message.incoming.reorder(nil).joins(:conversation)
           .where(account_id: account_id, conversations: { account_id: account_id, contact_inbox_id: ids })
           .group('conversations.contact_inbox_id')
           .maximum('messages.created_at')
  end

  # { conversation id => ids of the contact_inboxes of its customer }
  def self.customers_of(conversations)
    identities = ContactInbox.where(contact_id: conversations.map(&:contact_id).uniq, inbox_id: conversations.map(&:inbox_id).uniq)
                             .pluck(:id, :contact_id, :inbox_id, :source_id)
                             .group_by { |_id, contact_id, inbox_id, _source_id| [contact_id, inbox_id] }
    conversations.to_h do |conversation|
      known = identities.fetch([conversation.contact_id, conversation.inbox_id], []).map { |id, _contact, _inbox, source_id| [id, source_id] }
      [conversation.id, customer_ids(known, conversation.contact_inbox_id)]
    end
  end

  # The ids of the contact_inboxes that are one customer with contact_inbox_id. identities: [[id, source_id]] of the contact in the
  # inbox. All of them, unless the contact has two or more different phone numbers there: then the customer is the one number (its
  # identities, if it is written in more than one way) and the business scoped user ids are not guessed onto any of them.
  def self.customer_ids(identities, contact_inbox_id)
    numbers = identities.to_h { |id, source_id| [id, Whatsapp::ContactIdentityResolver.phone_source_id(source_id)] }.compact
    return (identities.map(&:first) + [contact_inbox_id]).compact.uniq if numbers.values.uniq.size <= 1

    own_number = numbers[contact_inbox_id]
    ([contact_inbox_id] + numbers.select { |_id, number| number == own_number }.keys).compact.uniq
  end

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
