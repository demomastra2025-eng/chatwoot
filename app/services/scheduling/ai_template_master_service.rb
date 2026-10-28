# frozen_string_literal: true

class Scheduling::AiTemplateMasterService
  MODEL_NAME = 'openai/gpt-6.1-terra'

  SCENARIO_DEFINITIONS = [
    {
      key: 'created_confirmation',
      preset_key: 'appointment_created',
      template_name: 'booking_created_notice',
      title: 'Запись создана — запрос подтверждения',
      purpose: 'Клиент только что записался на приём. Сообщить дату, время и специалиста, попросить подтвердить или перенести запись.',
      variables: ['{{имя клиента}}', '{{дата записи}}', '{{время записи}}', '{{специалист}}']
    },
    {
      key: 'rescheduled_notice',
      preset_key: 'appointment_rescheduled',
      template_name: 'booking_rescheduled_notice',
      title: 'Запись перенесена',
      purpose: 'Запись клиента перенесена на новую дату и время. Сообщить новые дату, время и специалиста, попросить подтвердить.',
      variables: ['{{имя клиента}}', '{{дата записи}}', '{{время записи}}', '{{специалист}}']
    },
    {
      key: 'cancelled_notice',
      preset_key: 'appointment_cancelled',
      template_name: 'booking_cancelled_notice',
      title: 'Запись отменена',
      purpose: 'Запись клиента на указанную дату и время была отменена. Предложить выбрать новое время или связаться с клиникой.',
      variables: ['{{имя клиента}}', '{{дата записи}}', '{{время записи}}']
    },
    {
      key: 'reminder_24h',
      preset_key: 'appointment_day_before',
      template_name: 'booking_reminder_1d',
      title: 'Напоминание за 1 день',
      purpose: 'Напомнить клиенту за 1 день о предстоящем приёме (дата, время, специалист) и попросить подтвердить визит.',
      variables: ['{{имя клиента}}', '{{дата записи}}', '{{время записи}}', '{{специалист}}']
    },
    {
      key: 'reminder_2h',
      preset_key: 'appointment_two_hours_before',
      template_name: 'booking_reminder_2h',
      title: 'Напоминание за 2 часа',
      purpose: 'Кратко напомнить клиенту за 2 часа о сегодняшнем визите (время и специалист).',
      variables: ['{{имя клиента}}', '{{время записи}}', '{{специалист}}']
    },
    {
      key: 'post_visit_feedback',
      preset_key: 'appointment_review_request',
      template_name: 'booking_feedback_request',
      title: 'Запрос отзыва после визита',
      purpose: 'Поблагодарить клиента за визит к специалисту и вежливо попросить оценить приём.',
      variables: ['{{имя клиента}}', '{{специалист}}']
    }
  ].freeze

  POSITIONAL_TO_RUSSIAN_TOKEN = {
    1 => '{{имя клиента}}',
    2 => '{{дата записи}}',
    3 => '{{время записи}}',
    4 => '{{специалист}}'
  }.freeze

  def initialize(account:, language: nil, languages: nil, bilingual: nil, scenario_keys: nil, options: {}, **_extra)
    @account = account
    @options = (options || {}).with_indifferent_access
    @bilingual = bilingual.nil? ? @account.bilingual_templates_enabled? : ActiveModel::Type::Boolean.new.cast(bilingual)
    @languages = resolve_languages(language, languages)
    @language = @languages.first || @account.primary_client_language
    @scenario_definitions = filter_scenarios(scenario_keys)
  end

  def call
    clinic_context = build_clinic_context
    llm_used = false
    templates = []

    if @bilingual
      secondary_lang = (@languages - [@language]).first || (@account.client_languages - [@language]).first || (@language == 'ru' ? 'kk' : 'ru')
      ai_items, used = fetch_ai_templates(clinic_context, language: @language, secondary_lang: secondary_lang, bilingual: true)
      llm_used ||= used
      templates = build_templates_for_language(
        clinic_context: clinic_context,
        language: @language,
        secondary_lang: secondary_lang,
        bilingual: true,
        ai_items: ai_items
      )
    else
      @languages.each do |lang|
        ai_items, used = fetch_ai_templates(clinic_context, language: lang, secondary_lang: nil, bilingual: false)
        llm_used ||= used
        templates.concat(
          build_templates_for_language(
            clinic_context: clinic_context,
            language: lang,
            secondary_lang: nil,
            bilingual: false,
            ai_items: ai_items
          )
        )
      end
    end

    packs = @languages.map do |lang|
      lang_templates = @bilingual ? templates : templates.select { |t| t[:language] == lang }
      {
        language: lang,
        language_label: Whatsapp::SupportedLanguages.label_for(lang),
        bilingual: @bilingual,
        templates: lang_templates
      }
    end

    {
      model: MODEL_NAME,
      llm_used: llm_used,
      language: @language,
      languages: @languages,
      bilingual: @bilingual,
      clinic_context: clinic_context,
      drafts: templates,
      templates: templates,
      packs: packs
    }
  end

  private

  def resolve_languages(language, languages)
    raw_list = if languages.present?
                 Array(languages)
               elsif language.present?
                 [language]
               else
                 @account.client_languages
               end
    normalized = Whatsapp::SupportedLanguages.normalize_list(raw_list)
    normalized.presence || [@account.primary_client_language]
  end

  def filter_scenarios(scenario_keys)
    keys = Array(scenario_keys).map(&:to_s).map(&:strip).reject(&:blank?)
    return SCENARIO_DEFINITIONS if keys.empty?

    filtered = SCENARIO_DEFINITIONS.select do |sc|
      keys.include?(sc[:key]) || keys.include?(sc[:preset_key]) || keys.include?(sc[:template_name])
    end
    filtered.presence || SCENARIO_DEFINITIONS
  end

  def build_clinic_context
    services = if @account.respond_to?(:scheduling_services)
                 @account.scheduling_services.where(active: true).limit(8).pluck(:name)
               else
                 []
               end
    specialists = if @account.respond_to?(:scheduling_resources)
                    @account.scheduling_resources.where(active: true).limit(6).pluck(:name)
                  else
                    []
                  end
    cabinets = if @account.respond_to?(:scheduling_resources)
                 @account.scheduling_resources.where(active: true).where.not(specialty: [nil, '']).distinct.limit(4).pluck(:specialty)
               else
                 []
               end
    custom_name = (@options[:company_name_ru].presence || @options[:company_name_kk].presence).to_s.strip.presence

    {
      clinic_name: custom_name || @account.name.to_s.strip.presence || 'нашей клинике',
      services: services,
      specialists: specialists,
      cabinets: cabinets
    }
  end

  def fetch_ai_templates(clinic_context, language:, secondary_lang:, bilingual:)
    messages = [
      { role: 'system', content: system_prompt(clinic_context, language: language, secondary_lang: secondary_lang, bilingual: bilingual) },
      { role: 'user', content: user_prompt(clinic_context, language: language, secondary_lang: secondary_lang, bilingual: bilingual) }
    ]

    response = Llm::Runtime.chat(
      feature: :editor,
      account: @account,
      model: MODEL_NAME,
      messages: messages,
      options: { max_tokens: 2200 },
      observability: { operation: 'scheduling.ai_template_master' }
    )

    parsed = parse_json_response(response&.content.to_s)
    items = Array(parsed['templates'])
    [items, items.any?]
  rescue StandardError => e
    Rails.logger.warn("[Scheduling::AiTemplateMasterService] LLM fallback model=#{MODEL_NAME} error=#{e.class}: #{e.message}")
    [[], false]
  end

  def parse_json_response(raw_text)
    cleaned = raw_text.to_s.strip
    cleaned = cleaned.sub(/\A```(?:json)?\s*/i, '').sub(/\s*```\z/, '')
    JSON.parse(cleaned)
  rescue JSON::ParserError
    {}
  end

  def system_prompt(_clinic_context, language:, secondary_lang:, bilingual:)
    lang_instruction = if bilingual
                         "Пиши двуязычные сообщения в одном шаблоне (сначала #{Whatsapp::SupportedLanguages.label_for(language)}, затем через пустую строку короткий перевод на #{Whatsapp::SupportedLanguages.label_for(secondary_lang)}), укладываясь в 380 символов."
                       else
                         "Пиши строго на языке: #{Whatsapp::SupportedLanguages.label_for(language)} (код #{language})."
                       end

    <<~PROMPT
      Ты — мастер создания сервисных WhatsApp-шаблонов (категория UTILITY) для медицинской клиники.
      #{lang_instruction}

      ЖЁСТКИЕ ПРАВИЛА META UTILITY И ГРАММАТИКИ:
      1. Опирайся ТОЛЬКО на данные компании. Не выдумывай адреса, телефоны, скидки, акции или услуги, которых нет в данных.
      2. Запрещены любые рекламные и маркетинговые слова (скидка, акция, бонус, подарок, бесплатно, жеңілдік, науқан, тегін и т.д.).
      3. Используй ТОЛЬКО указанные для каждого сценария семантические переменные в двойных фигурных скобках: {{имя клиента}}, {{дата записи}}, {{время записи}}, {{специалист}}.
      4. Переменная НЕ может стоять в самом начале или в самом конце текста шаблона (даже перед точкой или восклицательным знаком). После последней переменной обязательно добавь 1–3 нейтральных слова.
      5. Переменные НЕ могут идти подряд без слов между ними.
      6. КРИТИЧЕСКОЕ ПРАВИЛО ДЛЯ КАЗАХСКОГО И ТЮРКСКИХ ЯЗЫКОВ: НИКОГДА не приклеивай падежные окончания к переменным через дефис (ЗАПРЕЩЕНО: «{{время записи}}-ке», «{{дата записи}}-де», «{{специалист}}-ке», «{{3}}-ке»). Вместо этого перестраивай фразу так, чтобы переменная стояла в именительной форме перед служебным словом: «{{дата записи}} күні», «сағат {{время записи}} уақытында», «маман {{специалист}} қабылдауына».
      7. Длина текста body — до 380 символов. Длина текста каждой кнопки (buttons) — строго до 20 символов, максимум 2 кнопки.
      8. Верни ответ ТОЛЬКО в формате валидного JSON: {"templates": [{"template_name": "...", "body": "...", "buttons": ["...", "..."]}]}.
    PROMPT
  end

  def user_prompt(clinic_context, language:, secondary_lang:, bilingual:)
    scenarios_json = @scenario_definitions.map do |sc|
      {
        scenario_key: sc[:key],
        template_name: sc[:template_name],
        title: sc[:title],
        purpose: sc[:purpose],
        required_variables: sc[:variables]
      }
    end

    <<~USER
      Данные компании:
      - Название клиники: #{clinic_context[:clinic_name]}
      - Примеры услуг клиники (для понимания профиля, не вставляй весь список в шаблон): #{clinic_context[:services].join(', ').presence || 'медицинский приём'}
      - Режим: #{bilingual ? "Два языка в одном сообщении (#{language} + #{secondary_lang})" : "Один язык (#{language})"}

      Сгенерируй #{@scenario_definitions.size} шаблонов для сценариев:
      #{JSON.pretty_generate(scenarios_json)}
    USER
  end

  def build_templates_for_language(clinic_context:, language:, secondary_lang:, bilingual:, ai_items:)
    by_key = Array(ai_items).each_with_object({}) do |item, acc|
      next unless item.is_a?(Hash)

      item_lang = Whatsapp::SupportedLanguages.normalize_code(item['language'] || item[:language])
      next if item_lang.present? && !bilingual && item_lang != language

      k = (item['template_name'] || item[:template_name] || item['scenario_key'] || item[:scenario_key] || item['preset_key'] || item[:preset_key]).to_s.strip
      acc[k] = item if k.present?
    end

    @scenario_definitions.map do |scenario|
      ai_candidate = by_key[scenario[:template_name]] || by_key[scenario[:key]] || by_key[scenario[:preset_key]]
      fallback = fallback_template_for(
        scenario[:template_name],
        clinic_context: clinic_context,
        language: language,
        secondary_lang: secondary_lang,
        bilingual: bilingual
      )

      candidate_raw_body = (ai_candidate&.[]('body') || ai_candidate&.[]('body_text') || ai_candidate&.[](:body) || ai_candidate&.[](:body_text)).to_s.strip
      candidate_body = repair_ai_body(candidate_raw_body, scenario[:variables])
      candidate_buttons = Array(ai_candidate&.[]('buttons') || ai_candidate&.[](:buttons)).map do |b|
        b.is_a?(Hash) ? (b['text'] || b[:text]).to_s.strip : b.to_s.strip
      end.reject(&:blank?).first(2)

      body_to_use = candidate_body.presence || fallback[:body]
      buttons_to_use = candidate_buttons.presence || fallback[:buttons]

      validation = Whatsapp::TemplateUtilityValidator.new(
        body_text: body_to_use,
        buttons: buttons_to_use,
        language: language,
        category: 'UTILITY',
        bilingual: bilingual,
        expected_variables_count: scenario[:variables].size
      ).call

      unless validation.valid?
        body_to_use = fallback[:body]
        buttons_to_use = fallback[:buttons]
        validation = Whatsapp::TemplateUtilityValidator.new(
          body_text: body_to_use,
          buttons: buttons_to_use,
          language: language,
          category: 'UTILITY',
          bilingual: bilingual,
          expected_variables_count: scenario[:variables].size
        ).call
      end

      button_objects = buttons_to_use.map { |text| { type: 'QUICK_REPLY', text: text } }

      {
        preset_key: scenario[:preset_key],
        scenario_key: scenario[:key],
        template_name: scenario[:template_name],
        name: scenario[:template_name],
        title: scenario[:title],
        language: language,
        bilingual: bilingual,
        category: 'UTILITY',
        body: body_to_use,
        body_text: body_to_use,
        serialized_body: validation.serialized_body,
        serialized_body_text: validation.serialized_body_text,
        buttons: buttons_to_use,
        button_objects: button_objects,
        variable_keys: validation.variable_keys,
        validation: validation.to_h
      }
    end
  end

  def repair_ai_body(raw_body, scenario_variables)
    return '' if raw_body.blank?

    repaired = raw_body.dup
    # Remove hyphenated case endings glued to variables: e.g. {{3}}-ке -> {{3}}
    repaired.gsub!(/(\{\{[^{}]+\}\})\s*[-–—]\s*[[:alpha:]]+/u, '\1')
    # Convert positional {{1}}, {{2}} in AI output to the scenario's semantic tokens
    repaired.gsub!(/\{\{\s*(\d+)\s*\}\}/) do
      idx = Regexp.last_match(1).to_i
      scenario_variables[idx - 1] || POSITIONAL_TO_RUSSIAN_TOKEN[idx] || "{{#{idx}}}"
    end
    repaired
  end

  def fallback_template_for(template_name, clinic_context:, language:, secondary_lang:, bilingual:)
    clinic = clinic_context[:clinic_name]

    return fallback_bilingual_template(template_name, clinic) if bilingual

    case Whatsapp::SupportedLanguages.normalize_code(language)
    when 'kk'
      fallback_kk_template(template_name, clinic)
    when 'en'
      fallback_en_template(template_name, clinic)
    else
      fallback_ru_template(template_name, clinic)
    end
  end

  def fallback_ru_template(template_name, clinic)
    case template_name
    when 'booking_created_notice'
      {
        body: "Здравствуйте, {{имя клиента}}! Вы записаны в клинику «#{clinic}» на {{дата записи}} в {{время записи}} к специалисту {{специалист}}. Пожалуйста, подтвердите визит.",
        buttons: %w[Подтверждаю Перенести]
      }
    when 'booking_rescheduled_notice'
      {
        body: "Здравствуйте, {{имя клиента}}! Ваша запись в клинику «#{clinic}» перенесена на {{дата записи}} в {{время записи}} к специалисту {{специалист}}. Пожалуйста, подтвердите время.",
        buttons: %w[Подтверждаю Связаться]
      }
    when 'booking_cancelled_notice'
      {
        body: "Здравствуйте, {{имя клиента}}! Ваша запись в клинику «#{clinic}» на {{дата записи}} в {{время записи}} отменена. Если хотите выбрать другое время, напишите нам.",
        buttons: ['Новое время', 'Связаться']
      }
    when 'booking_reminder_1d'
      {
        body: "Здравствуйте, {{имя клиента}}! Напоминаем о записи в клинику «#{clinic}» на {{дата записи}} в {{время записи}} к специалисту {{специалист}}. Ждём вас.",
        buttons: %w[Подтверждаю Перенести]
      }
    when 'booking_reminder_2h'
      {
        body: "Здравствуйте, {{имя клиента}}! Напоминаем, что сегодня в {{время записи}} у вас приём в клинике «#{clinic}» у специалиста {{специалист}}. До встречи.",
        buttons: ['Буду вовремя', 'Опаздываю']
      }
    else
      {
        body: "Здравствуйте, {{имя клиента}}! Благодарим за визит в клинику «#{clinic}» к специалисту {{специалист}}. Пожалуйста, оцените, как прошёл приём.",
        buttons: ['Всё отлично', 'Есть вопрос']
      }
    end
  end

  def fallback_kk_template(template_name, clinic)
    case template_name
    when 'booking_created_notice'
      {
        body: "Сәлеметсіз бе, {{имя клиента}}! Сіз «#{clinic}» клиникасына {{дата записи}} күні сағат {{время записи}} уақытында маман {{специалист}} қабылдауына жазылдыңыз. Келуіңізді растаңызшы.",
        buttons: ['Растаймын', 'Уақытын өзгерту']
      }
    when 'booking_rescheduled_notice'
      {
        body: "Сәлеметсіз бе, {{имя клиента}}! Сіздің «#{clinic}» клиникасындағы жазылуыңыз {{дата записи}} күні сағат {{время записи}} уақытына маман {{специалист}} қабылдауына ауыстырылды.",
        buttons: %w[Растаймын Хабарласу]
      }
    when 'booking_cancelled_notice'
      {
        body: "Сәлеметсіз бе, {{имя клиента}}! Сіздің «#{clinic}» клиникасына {{дата записи}} күні сағат {{время записи}} уақытындағы жазылуыңыз тоқтатылды. Жаңа уақыт таңдау үшін жазыңыз.",
        buttons: ['Жаңа уақыт', 'Хабарласу']
      }
    when 'booking_reminder_1d'
      {
        body: "Сәлеметсіз бе, {{имя клиента}}! «#{clinic}» клиникасына {{дата записи}} күні сағат {{время записи}} уақытында маман {{специалист}} қабылдауына жазылғаныңызды еске саламыз.",
        buttons: ['Келемін', 'Уақытын өзгерту']
      }
    when 'booking_reminder_2h'
      {
        body: "Сәлеметсіз бе, {{имя клиента}}! Бүгін сағат {{время записи}} уақытында «#{clinic}» клиникасында маман {{специалист}} қабылдауы болатынын еске саламыз. Сізді күтеміз.",
        buttons: ['Уақытында келемін', 'Кешігемін']
      }
    else
      {
        body: "Сәлеметсіз бе, {{имя клиента}}! «#{clinic}» клиникасында маман {{специалист}} қабылдауында болғаныңызға рақмет. Қабылдау қалай өткенін бағалаңызшы.",
        buttons: ['Бәрі жақсы', 'Сұрағым бар']
      }
    end
  end

  def fallback_en_template(template_name, clinic)
    case template_name
    when 'booking_created_notice'
      {
        body: "Hello {{имя клиента}}! Your appointment at #{clinic} is scheduled for {{дата записи}} at {{время записи}} with {{специалист}}. Please confirm your visit.",
        buttons: %w[Confirm Reschedule]
      }
    when 'booking_rescheduled_notice'
      {
        body: "Hello {{имя клиента}}! Your appointment at #{clinic} has been moved to {{дата записи}} at {{время записи}} with {{специалист}}. Please confirm the new time.",
        buttons: ['Confirm', 'Contact us']
      }
    when 'booking_cancelled_notice'
      {
        body: "Hello {{имя клиента}}! Your appointment at #{clinic} on {{дата записи}} at {{время записи}} has been cancelled. Reply to choose a new time.",
        buttons: ['Book again', 'Contact us']
      }
    when 'booking_reminder_1d'
      {
        body: "Hello {{имя клиента}}! Reminder of your appointment at #{clinic} on {{дата записи}} at {{время записи}} with {{специалист}}. We look forward to seeing you.",
        buttons: %w[Confirm Reschedule]
      }
    when 'booking_reminder_2h'
      {
        body: "Hello {{имя клиента}}! Reminder that your appointment at #{clinic} today is at {{время записи}} with {{специалист}}. See you soon.",
        buttons: ['On my way', 'Running late']
      }
    else
      {
        body: "Hello {{имя клиента}}! Thank you for visiting #{clinic} and seeing {{специалист}}. Please let us know how your visit went.",
        buttons: ['Great visit', 'Have a question']
      }
    end
  end

  def fallback_bilingual_template(template_name, clinic)
    case template_name
    when 'booking_created_notice'
      {
        body: "Здравствуйте, {{имя клиента}}! Вы записаны в «#{clinic}» на {{дата записи}} в {{время записи}}, врач {{специалист}}. Подтвердите визит.\nСәлеметсіз бе! Жазылуыңызды растаңызшы.",
        buttons: ['Подтверждаю / Иә', 'Перенести']
      }
    when 'booking_rescheduled_notice'
      {
        body: "Здравствуйте, {{имя клиента}}! Запись в «#{clinic}» перенесена на {{дата записи}} в {{время записи}}, специалист {{специалист}}.\nЖазылу уақыты ауыстырылды, растаңызшы.",
        buttons: ['Подтверждаю / Иә', 'Связаться']
      }
    when 'booking_cancelled_notice'
      {
        body: "Здравствуйте, {{имя клиента}}! Запись в «#{clinic}» на {{дата записи}} в {{время записи}} отменена.\nЖазылуыңыз тоқтатылды. Жаңа уақыт таңдау үшін жазыңыз.",
        buttons: ['Новое время', 'Связаться']
      }
    when 'booking_reminder_1d'
      {
        body: "Здравствуйте, {{имя клиента}}! Напоминаем о записи в «#{clinic}»: {{дата записи}} в {{время записи}}, специалист {{специалист}}.\nЕртеңгі қабылдауды еске саламыз.",
        buttons: ['Подтверждаю / Иә', 'Перенести']
      }
    when 'booking_reminder_2h'
      {
        body: "Здравствуйте, {{имя клиента}}! Сегодня в {{время записи}} приём в «#{clinic}», специалист {{специалист}}. Ждём вас.\nБүгінгі қабылдауды еске саламыз.",
        buttons: ['Буду вовремя', 'Опаздываю']
      }
    else
      {
        body: "Здравствуйте, {{имя клиента}}! Спасибо за визит в «#{clinic}» к специалисту {{специалист}}. Оцените приём.\nҚабылдау қалай өткенін бағалаңызшы.",
        buttons: ['Отлично / Жақсы', 'Есть вопрос']
      }
    end
  end
end
