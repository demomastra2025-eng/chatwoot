class Integrations::Macrocrm::ProcessorService
  INCOMING_PREFIX = 'Входящее WhatsApp'.freeze
  OUTGOING_PREFIX = 'Исходящее WhatsApp'.freeze
  ATTACHMENT_PLACEHOLDER = '[Attachment]'.freeze
  CONTACT_NOT_FOUND_MESSAGE = 'No contacts found'.freeze

  pattr_initialize [:hook!, :event_name!, :message!]

  def perform
    return unless event_name == 'message.created'
    return unless eligible_message?

    contact = find_contact
    estate = find_last_estate(contact)
    sync_chat_manager_from_estate(estate) if estate.present?
    estate_id = estate&.dig('id') || create_estate_id(contact_name: contact&.dig('name'))
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

  def sync_chat_manager_from_macro?
    hook.settings.fetch('sync_chat_manager_from_macro', true)
  end

  def sync_chat_manager_to_macro?
    hook.settings.fetch('sync_chat_manager_to_macro', true)
  end

  def find_contact
    response = client.find_contact(phone: phone)
    return response['contact'] if response['contact'].present?
    return nil if contact_not_found_response?(response)
    return nil if response['contact'].blank? && response['error'] != true

    raise Integrations::Macrocrm::Client::ApiError, "Unexpected MacroCRM contact response: #{response}"
  end

  def contact_not_found_response?(response)
    response['error'] == true && response['message'] == CONTACT_NOT_FOUND_MESSAGE
  end

  def find_last_estate(contact)
    return nil unless contact&.dig('id').present?

    buys_response = client.find_estate_buy(contact_id: contact['id'])
    buys = buys_response['buys'] || []
    buys.last if buys.last&.dig('id').present?
  end

  def create_estate_id(contact_name: nil)
    payload = {
      name: contact_name.presence || name,
      phone: phone,
      message: text
    }
    manager_id = macro_manager_id_for_new_estate
    payload[:manager_id] = manager_id if manager_id.present?

    response = client.create_estate_buy(**payload)
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
      direct_phone = normalize_phone(message.conversation.contact.phone_number)
      return direct_phone if direct_phone.present?

      source_id = message.conversation.contact_inbox&.source_id.to_s.delete_prefix('whatsapp:')
      normalize_phone(source_id)
    end
  end

  def normalize_phone(value)
    raw_value = value.to_s.strip
    return if raw_value.blank?

    digits = raw_value.gsub(/\D/, '')
    return if digits.blank?

    "+#{digits}"
  end

  def sync_chat_manager_from_estate(estate)
    return unless sync_chat_manager_from_macro?

    manager_id = estate['manager_id']
    return if manager_id.blank?

    user = local_user_for_macro_manager(manager_id)
    return unless user.present?
    return if message.conversation.assignee_id == user.id

    assign_conversation_to(user)
  end

  def macro_manager_id_for_new_estate
    return unless sync_chat_manager_to_macro?

    user = local_chat_manager
    return if user.blank?

    manager_id = manager_mapping_for_user(user)&.dig(:macro_manager_id)
    manager_id ||= user.custom_attributes&.dig('macrocrm_manager_id')
    return manager_id.to_i if manager_id.present?

    Rails.logger.warn("[MacroCRM] Missing manager mapping for user ##{user.id} on hook ##{hook.id}")
    nil
  end

  def local_chat_manager
    current_assignee = message.conversation.assignee
    return current_assignee if assignable_to_conversation?(current_assignee)

    fallback_assignee = fallback_local_chat_manager
    return if fallback_assignee.blank?

    assign_conversation_to(fallback_assignee) unless message.conversation.assignee_id == fallback_assignee.id
    fallback_assignee
  end

  def fallback_local_chat_manager
    candidates = if message.conversation.team.present?
                   message.conversation.team.members.select { |user| assignable_to_conversation?(user) }
                 else
                   message.conversation.inbox.assignable_agents
                 end

    candidates.compact.sort_by { |user| user.name.to_s.downcase }.first
  end

  def assignable_to_conversation?(user)
    return false if user.blank?
    return false if message.conversation.team.present? && message.conversation.team.members.exclude?(user)

    message.conversation.inbox.members.exists?(user.id) || message.conversation.account.administrators.exists?(user.id)
  end

  def local_user_for_macro_manager(macro_manager_id)
    mapping = manager_mappings.find { |item| item[:macro_manager_id] == macro_manager_id.to_i }
    mapped_user = mapping && hook.account.users.find_by(id: mapping[:user_id])
    return mapped_user if assignable_to_conversation?(mapped_user)

    hook.account.users.find_each do |user|
      next unless assignable_to_conversation?(user)

      return user if user.custom_attributes&.dig('macrocrm_manager_id').to_s == macro_manager_id.to_s
    end

    nil
  end

  def manager_mapping_for_user(user)
    manager_mappings.find { |item| item[:user_id] == user.id }
  end

  def manager_mappings
    @manager_mappings ||= Array(hook.settings['manager_mappings']).filter_map do |item|
      next unless item.is_a?(Hash)

      user_id = item['user_id'] || item[:user_id]
      macro_manager_id = item['macro_manager_id'] || item[:macro_manager_id]
      next if user_id.blank? || macro_manager_id.blank?

      {
        user_id: user_id.to_i,
        macro_manager_id: macro_manager_id.to_i
      }
    end
  end

  def assign_conversation_to(user)
    previous_executor = Current.executed_by
    Current.executed_by = self.class.name
    Conversations::AssignmentService.new(conversation: message.conversation, assignee_id: user.id).perform
  ensure
    Current.executed_by = previous_executor
  end
end
