class Integrations::Macrocrm::ManagerChangedProcessorService
  CONTACT_NOT_FOUND_MESSAGE = 'No contacts found'.freeze
  PROCESSED_AT_KEY = Integrations::Macrocrm::ConversationAttributeKeys::MANAGER_CHANGED_AT
  LOG_PREFIX = '[MACROCRM][MANAGER_CHANGED]'.freeze

  pattr_initialize [:hook!, :payload!]

  def perform
    return if hook.disabled?
    return log_info('Skipped manager sync from MacroCRM because setting is disabled') unless sync_chat_manager_from_macro?
    return unless manager_changed_event?
    return if estate_id.blank?

    estate = estate_from_list || estate_from_fallback
    return log_warn('Estate not found', estate_id: estate_id) if estate.blank?

    conversation = find_target_conversation(resolved_phone(estate))
    return log_warn('Target conversation not found', estate_id: estate_id, phone: resolved_phone(estate)) if conversation.blank?
    return log_info('Ignored stale webhook', estate_id: estate_id, conversation_id: conversation.id, updated_at: updated_at_raw) if stale_webhook?(conversation)

    if estate[:manager_id].to_i.positive?
      assign_manager(conversation, estate[:manager_id])
    else
      clear_manager(conversation)
    end

    store_processed_timestamp(conversation)
  end

  private

  def client
    @client ||= Integrations::Macrocrm::Client.new(hook: hook)
  end

  def manager_changed_event?
    payload['action'] == 'estate.managerChanged' || payload.dig('data', 'event') == 'estate.managerChanged'
  end

  def sync_chat_manager_from_macro?
    hook.settings.fetch('sync_chat_manager_from_macro', true)
  end

  def estate_id
    @estate_id ||= payload.dig('data', 'object', 'estate_id').presence
  end

  def status
    payload.dig('data', 'object', 'status')
  end

  def webhook_phone
    @webhook_phone ||= normalize_phone(payload.dig('data', 'object', 'client_phones'))
  end

  def updated_at_raw
    payload.dig('data', 'object', 'updated_at')
  end

  def parsed_updated_at
    @parsed_updated_at ||= begin
      value = updated_at_raw.presence
      value ? Time.zone.parse(value) : nil
    rescue ArgumentError, TypeError
      nil
    end
  end

  def estate_from_list
    response = client.list_estate_buy(
      ids: [estate_id],
      statuses: Array(status).compact_blank
    )
    buy = Array(response['buys']).find { |item| item['id'].to_s == estate_id.to_s }
    return if buy.blank?

    {
      estate_id: buy['id'],
      manager_id: buy.dig('manager', 'id'),
      phones: Array(buy.dig('contact', 'phones')).filter_map { |phone| normalize_phone(phone) }
    }
  rescue Integrations::Macrocrm::Client::ApiError => e
    log_error('estateBuy/list failed', estate_id: estate_id, error: e.message)
    nil
  end

  def estate_from_fallback
    return if webhook_phone.blank?

    contact = find_contact
    return if contact.blank?

    buys_response = client.find_estate_buy(contact_id: contact['id'])
    buy = Array(buys_response['buys']).find { |item| item['id'].to_s == estate_id.to_s }
    return if buy.blank?

    {
      estate_id: buy['id'],
      manager_id: buy['manager_id'],
      phones: [webhook_phone]
    }
  rescue Integrations::Macrocrm::Client::ApiError => e
    log_error('Fallback estate lookup failed', estate_id: estate_id, phone: webhook_phone, error: e.message)
    nil
  end

  def find_contact
    response = client.find_contact(phone: webhook_phone)
    return response['contact'] if response['contact'].present?
    return nil if contact_not_found_response?(response)
    return nil if response['contact'].blank? && response['error'] != true

    raise Integrations::Macrocrm::Client::ApiError, "Unexpected MacroCRM contact response: #{response}"
  end

  def contact_not_found_response?(response)
    response['error'] == true && response['message'] == CONTACT_NOT_FOUND_MESSAGE
  end

  def resolved_phone(estate)
    webhook_phone.presence || Array(estate[:phones]).first
  end

  def find_target_conversation(phone)
    conversation = conversation_with_estate_reference
    return conversation if conversation.present?

    return if phone.blank?
    return if whatsapp_inbox_ids.blank?

    candidates = Conversation.joins(:contact, :contact_inbox)
                             .where(account_id: hook.account_id, inbox_id: whatsapp_inbox_ids)
                             .where(
                               'contacts.phone_number = :phone OR contact_inboxes.source_id IN (:source_ids)',
                               phone: phone,
                               source_ids: phone_lookup_variants(phone)
                             )

    pick_unambiguous_candidate(candidates.where.not(status: :resolved)) ||
      pick_unambiguous_candidate(candidates)
  end

  def conversation_with_estate_reference
    return if estate_id.blank?
    return if whatsapp_inbox_ids.blank?

    Conversation.where(account_id: hook.account_id, inbox_id: whatsapp_inbox_ids)
                .where(
                  "custom_attributes ->> 'macrocrm_estate_id' = ?",
                  estate_id.to_s
                )
                .order(last_activity_at: :desc, id: :desc)
                .first
  end

  def pick_unambiguous_candidate(scope)
    conversations = scope.order(last_activity_at: :desc, id: :desc).limit(2).to_a
    return conversations.first if conversations.one?

    nil
  end

  def whatsapp_inbox_ids
    @whatsapp_inbox_ids ||= begin
      native_whatsapp_ids = hook.account.inboxes.where(channel_type: 'Channel::Whatsapp').pluck(:id)
      twilio_whatsapp_ids = hook.account.inboxes.where(channel_type: 'Channel::TwilioSms')
                                    .includes(:channel)
                                    .select { |inbox| inbox.channel.medium == 'whatsapp' }
                                    .map(&:id)
      native_whatsapp_ids + twilio_whatsapp_ids
    end
  end

  def phone_lookup_variants(phone)
    digits = phone.to_s.delete_prefix('+')
    [phone, digits, "whatsapp:#{phone}", "whatsapp:#{digits}"].reject(&:blank?).uniq
  end

  def stale_webhook?(conversation)
    return false if parsed_updated_at.blank?

    last_processed_at = conversation.custom_attributes&.dig(PROCESSED_AT_KEY)
    return false if last_processed_at.blank?

    Time.zone.parse(last_processed_at) >= parsed_updated_at
  rescue ArgumentError, TypeError
    false
  end

  def assign_manager(conversation, macro_manager_id)
    user = local_user_for_macro_manager(macro_manager_id, conversation)
    return log_warn('Local assignable manager not found', estate_id: estate_id, macro_manager_id: macro_manager_id, conversation_id: conversation.id) if user.blank?
    return if conversation.assignee_id == user.id

    assign_conversation_to(conversation, user.id)
  end

  def clear_manager(conversation)
    return if conversation.assignee_id.blank? && conversation.assignee_agent_bot_id.blank?

    assign_conversation_to(conversation, nil)
  end

  def assignable_to_conversation?(user, conversation)
    return false if user.blank?
    return false if conversation.team.present? && conversation.team.members.exclude?(user)

    conversation.inbox.members.exists?(user.id) || conversation.account.administrators.exists?(user.id)
  end

  def macrocrm_assignable_agent?(user, conversation)
    return false unless assignable_to_conversation?(user, conversation)

    hook.account.account_users.find_by(user_id: user.id)&.agent?
  end

  def local_user_for_macro_manager(macro_manager_id, conversation)
    mapping = manager_mappings.find { |item| item[:macro_manager_id] == macro_manager_id.to_i }
    mapped_user = mapping && hook.account.users.find_by(id: mapping[:user_id])
    return mapped_user if macrocrm_assignable_agent?(mapped_user, conversation)

    hook.account.users.find_each do |user|
      next unless macrocrm_assignable_agent?(user, conversation)

      return user if user.custom_attributes&.dig('macrocrm_manager_id').to_s == macro_manager_id.to_s
    end

    nil
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

  def assign_conversation_to(conversation, assignee_id)
    previous_executor = Current.executed_by
    Current.executed_by = self.class.name
    Conversations::AssignmentService.new(conversation: conversation, assignee_id: assignee_id).perform
  ensure
    Current.executed_by = previous_executor
  end

  def store_processed_timestamp(conversation)
    return if parsed_updated_at.blank?

    # Avoid firing conversation updated callbacks for internal webhook bookkeeping.
    conversation.update_column(
      :custom_attributes,
      (conversation.custom_attributes || {}).merge(PROCESSED_AT_KEY => parsed_updated_at.utc.iso8601)
    )
  end

  def normalize_phone(value)
    raw_value = value.to_s.strip
    return if raw_value.blank?

    digits = raw_value.gsub(/\D/, '')
    return if digits.blank?

    "+#{digits}"
  end

  def log_info(message, context = {})
    Rails.logger.info("#{LOG_PREFIX} #{message} #{log_context(context)}")
  end

  def log_warn(message, context = {})
    Rails.logger.warn("#{LOG_PREFIX} #{message} #{log_context(context)}")
    nil
  end

  def log_error(message, context = {})
    Rails.logger.error("#{LOG_PREFIX} #{message} #{log_context(context)}")
  end

  def log_context(context)
    {
      hook_id: hook.id,
      account_id: hook.account_id,
      webhook_key: hook.reference_id
    }.merge(context).to_json
  end
end
