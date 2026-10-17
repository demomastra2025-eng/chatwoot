# frozen_string_literal: true

class Telephony::MissedCallWhatsappFollowupService
  DEFAULT_COOLDOWN_MINUTES = 60
  MIN_COOLDOWN_MINUTES = 5
  MAX_COOLDOWN_MINUTES = 1440
  DEFAULT_CUSTOM_MESSAGE = 'Здравствуйте! Вы звонили нам, но все линии были заняты. Чем мы можем помочь?'

  def initialize(call_session:)
    @call_session = call_session
    @account = call_session&.account
  end

  def perform
    return skipped('invalid_call_session') if call_session.blank? || account.blank?
    return skipped('not_unanswered_inbound') unless Telephony::MissedCallCallbackTracker.unanswered_inbound_terminal?(call_session)
    return skipped('already_sent_for_call') if already_sent_for_call?

    config = followup_config
    return skipped('followup_disabled') unless ActiveModel::Type::Boolean.new.cast(config['enabled'])

    whatsapp_inbox = resolve_whatsapp_inbox(config['inbox_id'])
    return skipped('whatsapp_inbox_not_found') if whatsapp_inbox.blank?

    contact = resolve_contact
    phone_number = resolve_phone_number(contact)
    return skipped('phone_number_missing') if phone_number.blank?

    window_minutes = cooldown_minutes(config)
    cooldown_key = build_cooldown_key(whatsapp_inbox.id, phone_number)
    return skipped('cooldown_active') if cooldown_active?(cooldown_key, whatsapp_inbox.id, phone_number, window_minutes)

    contact ||= ensure_contact!(phone_number)
    contact_inbox = ensure_contact_inbox!(contact, whatsapp_inbox, phone_number)
    conversation = ensure_conversation!(contact, whatsapp_inbox, contact_inbox)

    message = if official_waba_inbox?(whatsapp_inbox)
                send_official_template_message!(conversation, whatsapp_inbox, config)
              else
                send_custom_text_message!(conversation, whatsapp_inbox, config)
              end
    return skipped('message_not_created') if message.blank?

    Rails.cache.write(cooldown_key, Time.current.to_i, expires_in: window_minutes.minutes)
    record_followup_metadata!(whatsapp_inbox.id, message.id)

    {
      sent: true,
      message_id: message.id,
      conversation_id: conversation.id,
      whatsapp_inbox_id: whatsapp_inbox.id
    }
  end

  private

  attr_reader :call_session, :account

  def skipped(reason)
    { sent: false, reason: reason }
  end

  def already_sent_for_call?
    call_session.metadata.to_h.deep_stringify_keys.dig('missed_call_whatsapp_followup', 'sent_at').present?
  end

  def followup_config
    inbox = call_session.inbox
    return {} if inbox.blank?

    policy_routing = inbox.telephony_number_binding&.routing_policy&.settings&.to_h&.deep_stringify_keys&.dig('call_routing')
    channel_routing = inbox.channel.try(:provider_config)&.to_h&.deep_stringify_keys&.dig('call_routing')
    call_routing = policy_routing.presence || channel_routing.presence || {}

    call_routing.dig('inbound', 'whatsapp_followup').to_h.deep_stringify_keys
  end

  def resolve_whatsapp_inbox(inbox_id)
    return if inbox_id.blank?

    inbox = account.inboxes.find_by(id: inbox_id)
    return if inbox.blank?
    return inbox if inbox.channel_type.to_s.downcase.include?('whatsapp') || inbox.channel.try(:provider).to_s.downcase.include?('whatsapp') || inbox.channel.try(:provider).to_s == 'baileys'

    nil
  end

  def official_waba_inbox?(whatsapp_inbox)
    channel_type = whatsapp_inbox.channel_type.to_s
    provider = whatsapp_inbox.channel.try(:provider).to_s.downcase
    channel_type == 'Channel::Whatsapp' && !provider.in?(%w[baileys whatsapp_web])
  end

  def cooldown_minutes(config)
    raw = config['cooldown_minutes'].to_i
    raw = DEFAULT_COOLDOWN_MINUTES if raw <= 0
    raw.clamp(MIN_COOLDOWN_MINUTES, MAX_COOLDOWN_MINUTES)
  end

  def build_cooldown_key(whatsapp_inbox_id, phone_number)
    digits = phone_number.to_s.gsub(/\D/, '')
    "telephony:missed_call_wa_followup:#{account.id}:#{whatsapp_inbox_id}:#{digits}"
  end

  def cooldown_active?(cooldown_key, whatsapp_inbox_id, phone_number, window_minutes)
    return true if Rails.cache.read(cooldown_key).present?

    digits = phone_number.to_s.gsub(/\D/, '')
    return false if digits.blank?

    cutoff = window_minutes.minutes.ago
    Telephony::CallSession
      .where(account_id: account.id, direction: 'inbound')
      .where('created_at >= ?', cutoff)
      .where.not(id: call_session.id)
      .any? do |session|
        session_digits = session.from_number.to_s.gsub(/\D/, '')
        next false unless session_digits == digits

        meta = session.metadata.to_h.deep_stringify_keys['missed_call_whatsapp_followup']
        meta.is_a?(Hash) &&
          meta['sent_at'].present? &&
          meta['whatsapp_inbox_id'].to_i == whatsapp_inbox_id.to_i
      end
  end

  def resolve_contact
    call_session.contact || call_session.conversation&.contact
  end

  def resolve_phone_number(contact)
    raw = contact&.phone_number.presence || call_session.from_number.presence
    return if raw.blank?

    Contacts::PhoneNumberNormalizer.normalize(raw) ||
      Contacts::PhoneNumberNormalizer.normalize(raw, default_country: 'KZ') ||
      raw
  end

  def ensure_contact!(phone_number)
    account.contacts.find_or_create_by!(phone_number: phone_number) do |record|
      record.name = phone_number if record.name.blank?
    end
  end

  def ensure_contact_inbox!(contact, whatsapp_inbox, phone_number)
    existing = ContactInbox.find_by(contact_id: contact.id, inbox_id: whatsapp_inbox.id)
    return existing if existing.present?

    digits = phone_number.to_s.gsub(/\D/, '')
    source_id = whatsapp_inbox.channel_type == 'Channel::Whatsapp' ? (digits.presence || phone_number) : phone_number
    ContactInbox.find_by(inbox_id: whatsapp_inbox.id, source_id: source_id) ||
      ContactInbox.create!(contact: contact, inbox: whatsapp_inbox, source_id: source_id)
  end

  def ensure_conversation!(contact, whatsapp_inbox, contact_inbox)
    account.conversations.where(inbox_id: whatsapp_inbox.id, contact_id: contact.id).order(id: :desc).first ||
      account.conversations.create!(
        inbox: whatsapp_inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :open
      )
  end

  def send_official_template_message!(conversation, whatsapp_inbox, config)
    template_name = config['template_name'].to_s.strip
    return nil if template_name.blank?

    template_language = config['template_language'].to_s.strip.presence || 'ru'
    template_def = find_whatsapp_template(whatsapp_inbox, template_name, template_language)
    processed_params = build_template_processed_params(template_def, conversation.contact)
    fallback_text = config['custom_message'].to_s.strip.presence ||
                    render_template_body_preview(template_def, processed_params) ||
                    "Шаблон WhatsApp: #{template_name}"

    conversation.messages.create!(
      account: account,
      inbox: whatsapp_inbox,
      message_type: :outgoing,
      content: fallback_text,
      additional_attributes: {
        'template_params' => {
          'name' => template_name,
          'language' => template_def&.[]('language').presence || template_language,
          'category' => template_def&.[]('category').presence || 'UTILITY',
          'processed_params' => processed_params
        },
        'missed_call_whatsapp_followup' => true,
        'call_ref' => call_session.external_call_ref
      }
    )
  end

  def find_whatsapp_template(whatsapp_inbox, template_name, template_language)
    templates = whatsapp_inbox.channel.try(:message_templates)
    return nil unless templates.is_a?(Array)

    templates.find do |tpl|
      tpl.is_a?(Hash) &&
        tpl['name'].to_s == template_name &&
        tpl['language'].to_s.casecmp?(template_language)
    end || templates.find { |tpl| tpl.is_a?(Hash) && tpl['name'].to_s == template_name }
  end

  def build_template_processed_params(template_def, contact)
    return {} unless template_def.is_a?(Hash)

    body_component = Array(template_def['components']).find do |comp|
      comp.is_a?(Hash) && comp['type'].to_s.casecmp?('BODY')
    end
    body_text = body_component&.[]('text').to_s
    return {} if body_text.blank?

    placeholders = body_text.scan(/\{\{\s*([^}]+?)\s*\}\}/).flatten.map(&:strip).uniq
    return {} if placeholders.blank?

    contact_name = contact&.name.to_s.strip.presence || contact&.phone_number.to_s.strip.presence || call_session.from_number.to_s.strip.presence || 'Клиент'
    caller_phone = contact&.phone_number.to_s.strip.presence || call_session.from_number.to_s.strip.presence || contact_name

    body_params = placeholders.each_with_index.each_with_object({}) do |(key, idx), acc|
      acc[key] = if key == '2' || key.downcase.include?('phone')
                   caller_phone
                 elsif idx.zero? || key == '1' || key.downcase.include?('name')
                   contact_name
                 else
                   contact_name
                 end
    end

    { 'body' => body_params }
  end

  def render_template_body_preview(template_def, processed_params)
    return nil unless template_def.is_a?(Hash)

    body_component = Array(template_def['components']).find do |comp|
      comp.is_a?(Hash) && comp['type'].to_s.casecmp?('BODY')
    end
    body_text = body_component&.[]('text').to_s.strip
    return nil if body_text.blank?

    body_params = processed_params['body'].to_h
    body_text.gsub(/\{\{\s*([^}]+?)\s*\}\}/) do |match|
      key = Regexp.last_match(1).to_s.strip
      body_params[key].presence || match
    end
  end

  def send_custom_text_message!(conversation, whatsapp_inbox, config)
    content = config['custom_message'].to_s.strip.presence || DEFAULT_CUSTOM_MESSAGE

    conversation.messages.create!(
      account: account,
      inbox: whatsapp_inbox,
      message_type: :outgoing,
      content: content,
      additional_attributes: {
        'missed_call_whatsapp_followup' => true,
        'call_ref' => call_session.external_call_ref
      }
    )
  end

  def record_followup_metadata!(whatsapp_inbox_id, message_id)
    call_session.with_lock do
      metadata = (call_session.reload.metadata || {}).deep_dup
      metadata['missed_call_whatsapp_followup'] = {
        'sent_at' => Time.current.iso8601,
        'whatsapp_inbox_id' => whatsapp_inbox_id,
        'message_id' => message_id
      }
      call_session.update!(metadata: metadata)
    end
  end
end
