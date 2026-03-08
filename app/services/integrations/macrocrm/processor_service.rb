class Integrations::Macrocrm::ProcessorService
  INCOMING_PREFIX = 'Входящее WhatsApp'.freeze
  OUTGOING_PREFIX = 'Исходящее WhatsApp'.freeze
  ATTACHMENT_PLACEHOLDER = '[Attachment]'.freeze

  pattr_initialize [:hook!, :event_name!, :message!]

  def perform
    return unless event_name == 'message.created'
    return unless eligible_message?

    contact_response = client.find_contact(phone: phone)
    contact = contact_response['contact']
    estate_id = resolve_estate_id(contact)
    client.add_note(estate_id: estate_id, note: note)
  end

  private

  def client
    @client ||= Integrations::Macrocrm::Client.new(hook: hook)
  end

  def eligible_message?
    return false if hook.disabled?
    return false unless hook.account_id == message.account_id
    return false unless whatsapp_message?
    return false if message.private?
    return false unless message.webhook_sendable?
    return false if message.incoming? && !sync_incoming_messages?
    return false if message.outgoing? && !sync_outgoing_messages?
    return false if phone.blank?

    true
  end

  def whatsapp_message?
    message.inbox.whatsapp? || message.inbox.twilio_whatsapp?
  end

  def sync_incoming_messages?
    hook.settings.fetch('sync_incoming_messages', true)
  end

  def sync_outgoing_messages?
    hook.settings.fetch('sync_outgoing_messages', true)
  end

  def resolve_estate_id(contact)
    return create_estate_id unless contact&.dig('id').present?

    buys_response = client.find_estate_buy(contact_id: contact['id'])
    buys = buys_response['buys'] || []
    return buys.last['id'] if buys.last&.dig('id').present?

    create_estate_id(contact_name: contact['name'])
  end

  def create_estate_id(contact_name: nil)
    response = client.create_estate_buy(name: contact_name.presence || name, phone: phone, message: text)
    response.dig('estate', 'id').presence || raise(Integrations::Macrocrm::Client::ApiError, 'MacroCRM estate id missing in create response')
  end

  def note
    "[#{direction_prefix}] #{text}"
  end

  def direction_prefix
    message.incoming? ? INCOMING_PREFIX : OUTGOING_PREFIX
  end

  def text
    @text ||= begin
      content = message.outgoing? ? message.outgoing_content : message.content
      content = message.content if content.blank?
      content = ATTACHMENT_PLACEHOLDER if content.blank? && message.attachments.any?
      content.presence || ATTACHMENT_PLACEHOLDER
    end
  end

  def name
    @name ||= message.conversation.contact.name.presence || phone
  end

  def phone
    @phone ||= begin
      direct_phone = message.conversation.contact.phone_number.presence
      return direct_phone if direct_phone.present?

      source_id = message.conversation.contact_inbox&.source_id.to_s
      normalized_phone = source_id.delete_prefix('whatsapp:')
      normalized_phone.start_with?('+') ? normalized_phone : "+#{normalized_phone}"
    end
  end
end
