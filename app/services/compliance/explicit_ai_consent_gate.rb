# frozen_string_literal: true

# Optional per-workspace explicit patient consent gate before the first external LLM call
# (RK Personal Data Law Art. 7-8 & RK Law on Artificial Intelligence Art. 14).
# Disabled (false) by default for all clinics; enabled per clinic via
# Captain::AccountSettings (`safety.require_explicit_ai_consent`).
# rubocop:disable Metrics/ModuleLength
module Compliance::ExplicitAiConsentGate
  ALMATY_TIME_ZONE = 'Asia/Almaty'
  PROMPT_COOLDOWN_SECONDS = 60

  AFFIRMATIVE_EXACT_PATTERN = /
    \A[\s«"'(]*
    (?:1|да|согласен|согласна|соглашаюсь|подтверждаю|ок|окей|ok|okay|yes|
       иә|ия|иа|келісемін|келисемин|жақсы|жаксы|мақұл)
    [\s»"')!.?,]*\z
  /xiu

  AFFIRMATIVE_PREFIX_PATTERN = /
    \A[\s«"'(]*
    (?:1(?=\s|[,.!?;:»"')])|
       (?:да|согласен|согласна|соглашаюсь|подтверждаю|иә|ия|иа|келісемін|келисемин)(?=[\s,.!?;:»"')]|\z))
  /xiu

  NEGATIVE_PATTERN = /
    \A[\s«"'(]*
    (?:0|нет|не\s+согласен|не\s+согласна|отказ|отказываюсь|
       оператор|администратор|человек|сотрудник|менеджер|
       жоқ|жок|келіспеймін|маман)
    [\s»"')!.?,]*\z
  /xiu

  KAZAKH_LETTERS_PATTERN = /[әіңғүұқөһӘІҢҒҮҰҚӨҺ]/u

  PROMPTS = {
    'ru' => [
      [
        'Здравствуйте! Чтобы виртуальный ИИ-ассистент клиники помог вам быстрее, подтвердите согласие',
        'на обработку сообщений и персональных данных согласно Политике конфиденциальности.'
      ].join(' '),
      '',
      'Ответьте «1» или «Да» — продолжить с ИИ-ассистентом («Иә» — ЖИ-көмекшімен жалғастыру).',
      'Ответьте «0» или «Оператор» — переключить на сотрудника клиники («0» — маманға қосу).'
    ].join("\n"),
    'kk' => [
      [
        'Сәлеметсіз бе! Клиниканың виртуалды ЖИ-көмекшісі сізге тезірек көмектесуі үшін Құпиялылық',
        'саясатына сәйкес хабарламалар мен дербес деректерді өңдеуге келісіміңізді растаңыз.'
      ].join(' '),
      '',
      '«1» немесе «Иә» деп жауап беріңіз — ЖИ-көмекшімен жалғастыру («Да» — продолжить с ИИ).',
      '«0» немесе «Оператор» деп жауап беріңіз — клиника қызметкеріне қосу («0» — сотрудник клиники).'
    ].join("\n")
  }.freeze

  DECLINE_MESSAGES = {
    'ru' => 'Принято. Переключаю диалог на администратора клиники — специалист скоро ответит вам.',
    'kk' => 'Қабылданды. Диалогты клиника әкімшісіне қосамын — маман жақын арада жауап береді.'
  }.freeze

  module_function

  def enabled_for?(account)
    return false if account.blank? || !defined?(Captain::AccountSettings)

    Captain::AccountSettings.new(account).section('safety')['require_explicit_ai_consent'] == true
  rescue StandardError
    false
  end

  def granted?(contact)
    contact&.custom_attributes.to_h['ai_consent_status'].to_s == 'granted'
  end

  def declined?(contact)
    contact&.custom_attributes.to_h['ai_consent_status'].to_s == 'declined'
  end

  def blocked?(conversation)
    return false if conversation.blank? || !enabled_for?(conversation.account)

    !granted?(conversation.contact)
  end

  def evaluate_incoming!(conversation:, message:)
    return :allow if conversation.blank? || !enabled_for?(conversation.account)

    contact = conversation.contact
    return :allow if granted?(contact)

    text = message&.content.to_s.strip
    decision = evaluate_prompt_reply(conversation, contact, message, text)
    return decision if decision

    handle_unconsented_turn!(conversation, contact, text)
  end

  def evaluate_prompt_reply(conversation, contact, message, text)
    return unless prompt_sent?(conversation)
    return record_grant!(conversation, contact, message) if affirmative_reply?(text)

    record_decline!(conversation, contact, message, text) if negative_reply?(text)
  end

  def handle_unconsented_turn!(conversation, contact, text)
    if declined?(contact)
      handoff_to_staff!(conversation)
      return :declined
    end

    return :awaiting_consent if recently_prompted?(conversation)

    send_consent_prompt!(conversation, text)
    :prompted
  end

  def affirmative_reply?(text)
    text.present? && (text.match?(AFFIRMATIVE_EXACT_PATTERN) || text.match?(AFFIRMATIVE_PREFIX_PATTERN))
  end

  def negative_reply?(text)
    text.present? && text.match?(NEGATIVE_PATTERN)
  end

  def prompt_sent?(conversation)
    conversation.additional_attributes.to_h['ai_consent_prompt_sent_at'].present?
  end

  def recently_prompted?(conversation)
    raw = conversation.additional_attributes.to_h['ai_consent_prompt_sent_at']
    return false if raw.blank?

    Time.zone.parse(raw.to_s) >= PROMPT_COOLDOWN_SECONDS.seconds.ago
  rescue ArgumentError, TypeError
    false
  end

  def record_grant!(conversation, contact, message)
    persist_contact_consent!(conversation, contact, message, 'granted', 'ai_consent_granted_at')
    enqueue_deferred_attachments!(conversation)
    :allow
  end

  def record_decline!(conversation, contact, message, text)
    persist_contact_consent!(conversation, contact, message, 'declined', 'ai_consent_declined_at')
    lang = detect_local_language(text, conversation)
    send_local_outgoing_message!(conversation, DECLINE_MESSAGES.fetch(lang), 'ai_consent_declined')
    handoff_to_staff!(conversation)
    :declined
  end

  def persist_contact_consent!(conversation, contact, message, status, timestamp_key)
    return if contact.blank?

    attrs = contact.custom_attributes.to_h.merge(
      'ai_consent_status' => status,
      timestamp_key => Time.current.in_time_zone(ALMATY_TIME_ZONE).iso8601,
      'ai_consent_message_id' => message&.id,
      'ai_consent_channel' => conversation.inbox&.channel_type.to_s
    ).compact
    contact.skip_runtime_events = true if contact.respond_to?(:skip_runtime_events=)
    contact.update!(custom_attributes: attrs)
  end

  def enqueue_deferred_attachments!(conversation)
    account = conversation.account
    conversation.messages.incoming.includes(:attachments).find_each do |msg|
      msg.attachments.each { |att| enqueue_single_deferred_attachment!(att, account) }
    end
  rescue StandardError => e
    Rails.logger.warn("[Compliance::ExplicitAiConsentGate] deferred attachments warning conv=#{conversation.id}: #{e.class}")
  end

  def enqueue_single_deferred_attachment!(att, account)
    case att.file_type.to_sym
    when :audio then enqueue_deferred_audio!(att, account)
    when :file then enqueue_deferred_document!(att, account)
    when :image then enqueue_deferred_image!(att)
    end
  end

  def enqueue_deferred_audio!(att, account)
    return unless defined?(Messages::AudioTranscriptionJob) && account&.audio_transcriptions_enabled?
    return if att.meta.to_h['transcribed_text'].present?

    Messages::AudioTranscriptionJob.perform_later(att.id)
  end

  def enqueue_deferred_document!(att, account)
    return unless defined?(Messages::DocumentParsingService) && Messages::DocumentParsingService.pending_attachment?(att, account: account)

    Messages::DocumentParsingJob.perform_later(att.id)
  end

  def enqueue_deferred_image!(att)
    return unless defined?(Messages::ImageDescriptionService) && Messages::ImageDescriptionService.enabled_for?(att)

    Messages::ImageDescriptionJob.perform_later(att.id)
  end

  # rubocop:disable Rails/SkipsModelValidations
  def send_consent_prompt!(conversation, text)
    lang = detect_local_language(text, conversation)
    send_local_outgoing_message!(conversation, PROMPTS.fetch(lang), 'ai_consent_prompt')
    updated = conversation.additional_attributes.to_h.merge(
      'ai_consent_prompt_sent_at' => Time.current.utc.iso8601,
      'ai_consent_prompt_language' => lang
    )
    conversation.update_column(:additional_attributes, updated)
  end
  # rubocop:enable Rails/SkipsModelValidations

  def send_local_outgoing_message!(conversation, content, template_type)
    conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      content: content,
      content_attributes: { 'compliance_gate' => template_type }
    )
  end

  def handoff_to_staff!(conversation)
    if conversation.respond_to?(:bot_handoff!) && conversation.pending?
      conversation.bot_handoff!
    elsif conversation.pending?
      conversation.open!
    end
  rescue StandardError => e
    Rails.logger.warn("[Compliance::ExplicitAiConsentGate] handoff warning conv=#{conversation.id}: #{e.class}")
  end

  def detect_local_language(text, conversation)
    return 'kk' if kazakh_text?(text)

    stored = conversation.additional_attributes.to_h['ai_consent_prompt_language'].to_s
    stored == 'kk' ? 'kk' : 'ru'
  end

  def kazakh_text?(text)
    return false if text.blank?
    return true if text.match?(KAZAKH_LETTERS_PATTERN)

    defined?(Captain::KazakhMarkers) && Captain::KazakhMarkers.kazakh?(text)
  rescue StandardError
    false
  end
end
# rubocop:enable Metrics/ModuleLength
