# frozen_string_literal: true

class Whatsapp::TemplateUtilityValidator
  MAX_BODY_LENGTH = 400
  MAX_BUTTON_TEXT_LENGTH = 20
  MAX_QUICK_REPLY_BUTTONS = 3

  SEMANTIC_VARIABLE_ALIASES = {
    'имя клиента' => 'client_name',
    'имя пациента' => 'client_name',
    'клиент' => 'client_name',
    'пациент' => 'client_name',
    'client_name' => 'client_name',
    'contact_name' => 'client_name',
    'patient_name' => 'client_name',
    'дата записи' => 'appointment_date',
    'дата визита' => 'appointment_date',
    'дата приема' => 'appointment_date',
    'дата приёма' => 'appointment_date',
    'appointment_date' => 'appointment_date',
    'время записи' => 'appointment_time',
    'время визита' => 'appointment_time',
    'время приема' => 'appointment_time',
    'время приёма' => 'appointment_time',
    'appointment_time' => 'appointment_time',
    'специалист' => 'specialist_name',
    'врач' => 'specialist_name',
    'доктор' => 'specialist_name',
    'specialist_name' => 'specialist_name',
    'doctor_name' => 'specialist_name',
    'услуга' => 'service_name',
    'процедура' => 'service_name',
    'service_name' => 'service_name',
    'кабинет' => 'cabinet_name',
    'филиал' => 'cabinet_name',
    'cabinet_name' => 'cabinet_name',
    'клиника' => 'clinic_name',
    'компания' => 'clinic_name',
    'clinic_name' => 'clinic_name'
  }.freeze

  POSITIONAL_FALLBACK_KEYS = %w[
    client_name
    appointment_date
    appointment_time
    specialist_name
    service_name
    cabinet_name
    clinic_name
  ].freeze

  PROMOTIONAL_STOP_WORDS_REGEX = /(?:\b(?:скидк[аиуеой]|акци[яиюей]|распродаж[аиуе]|промокод\w*|бонус\w*|кэшбэк\w*|кешбэк\w*|подарок\w*|бесплатн\w*|выгодн\w*|спецпредложени\w*|купон\w*|sale|discount|promo|cashback|free\s+gift)\b|жеңілдік\w*|науқан\w*|сыйлық\w*|тегін)/iu

  HYPHEN_SUFFIX_AFTER_VARIABLE_REGEX = /\{\{[^{}]+\}\}\s*[-–—]\s*[[:alpha:]]+/u
  ADJACENT_VARIABLES_REGEX = /\{\{[^{}]+\}\}\s*\{\{[^{}]+\}\}/u
  LEADING_VARIABLE_REGEX = /\A\s*\{\{[^{}]+\}\}/u
  TRAILING_VARIABLE_REGEX = /\{\{[^{}]+\}\}[\s.!?…,:;»"')\]}]*\z/u
  KAZAKH_SPECIFIC_CHARS_REGEX = /[әғқңөұүһіӘҒҚҢӨҰҮҺІ]/u

  Result = Struct.new(
    :valid,
    :errors,
    :warnings,
    :error_codes,
    :serialized_body,
    :serialized_body_text,
    :variables,
    :variable_keys,
    :variables_count,
    keyword_init: true
  ) do
    def valid?
      Boolean(valid)
    end

    def [](key)
      sym = key.to_sym
      respond_to?(sym) ? public_send(sym) : nil
    end

    def dig(*keys)
      to_h.dig(*keys.map(&:to_sym))
    end

    def as_json(options = nil)
      to_h.as_json(options)
    end

    private

    def Boolean(val)
      ActiveModel::Type::Boolean.new.cast(val)
    end
  end

  class << self
    def validate(**)
      new(**).call
    end

    def hyphen_suffix_after_variable?(text)
      HYPHEN_SUFFIX_AFTER_VARIABLE_REGEX.match?(text.to_s)
    end

    def promotional_text?(text)
      PROMOTIONAL_STOP_WORDS_REGEX.match?(text.to_s)
    end

    def serialize_semantic_variables(text)
      source = text.to_s
      variable_keys = []
      key_to_index = {}

      serialized = source.gsub(/\{\{\s*([^{}]+?)\s*\}\}/) do |_full_match|
        raw_token = Regexp.last_match(1).to_s.strip
        if raw_token.match?(/\A\d+\z/)
          idx = raw_token.to_i
          canonical = POSITIONAL_FALLBACK_KEYS[idx - 1] || "var_#{idx}"
          variable_keys << canonical unless variable_keys.include?(canonical)
          "{{#{idx}}}"
        else
          normalized_token = raw_token.downcase.gsub(/\s+/, ' ')
          canonical = SEMANTIC_VARIABLE_ALIASES[normalized_token] || normalized_token.parameterize(separator: '_').presence || 'custom_var'
          unless key_to_index.key?(canonical)
            variable_keys << canonical
            key_to_index[canonical] = variable_keys.length
          end
          "{{#{key_to_index[canonical]}}}"
        end
      end

      [serialized, variable_keys]
    end
  end

  def initialize(
    body_text: nil,
    body: nil,
    buttons: [],
    language: 'ru',
    category: 'UTILITY',
    expected_variables_count: nil,
    strict_length: true,
    strict_trailing: true,
    bilingual: false,
    languages: [],
    **_extra
  )
    @raw_body = (body_text.presence || body).to_s.strip
    @buttons = Array(buttons)
    @language = language
    @category = (category.presence || 'UTILITY').to_s.upcase
    @expected_variables_count = expected_variables_count
    @strict_length = strict_length
    @strict_trailing = strict_trailing
    @bilingual = ActiveModel::Type::Boolean.new.cast(bilingual)
    @languages = Array(languages)
  end

  def call
    errors = []
    warnings = []
    error_codes = []

    normalized_lang = Whatsapp::SupportedLanguages.normalize_code(@language) || 'ru'
    button_texts = extract_button_texts(@buttons)
    serialized_body, variable_keys = self.class.serialize_semantic_variables(@raw_body)

    if @raw_body.blank?
      add_error(errors, error_codes, 'empty_body', 'Текст шаблона не может быть пустым.')
      return build_result(errors, warnings, error_codes, '', [], [])
    end

    if @strict_length && serialized_body.length > MAX_BODY_LENGTH
      add_error(
        errors,
        error_codes,
        'body_too_long',
        "Текст шаблона слишком длинный (#{serialized_body.length} симв., максимум #{MAX_BODY_LENGTH})."
      )
    end

    if @category != 'UTILITY'
      add_error(errors, error_codes, 'non_utility_category', 'Категория шаблона для уведомлений расписания должна быть UTILITY.')
    end

    if self.class.promotional_text?(@raw_body) || button_texts.any? { |btn| self.class.promotional_text?(btn) }
      add_error(
        errors,
        error_codes,
        'promotional_stop_words',
        'Шаблон содержит рекламные/промо стоп-слова (скидки, акции, бонусы), которые Meta отклоняет в категории UTILITY.'
      )
    end

    if LEADING_VARIABLE_REGEX.match?(@raw_body) || LEADING_VARIABLE_REGEX.match?(serialized_body)
      add_error(errors, error_codes, 'leading_variable', 'Шаблон не может начинаться с переменной.')
    end

    if @strict_trailing && (TRAILING_VARIABLE_REGEX.match?(@raw_body) || TRAILING_VARIABLE_REGEX.match?(serialized_body))
      add_error(
        errors,
        error_codes,
        'trailing_variable',
        'Шаблон не должен заканчиваться переменной — добавьте вежливое завершение фразы после переменной.'
      )
    end

    if ADJACENT_VARIABLES_REGEX.match?(@raw_body) || ADJACENT_VARIABLES_REGEX.match?(serialized_body)
      add_error(errors, error_codes, 'adjacent_variables', 'Переменные не могут идти подряд без текста между ними.')
    end

    if self.class.hyphen_suffix_after_variable?(@raw_body) || self.class.hyphen_suffix_after_variable?(serialized_body)
      add_error(
        errors,
        error_codes,
        'hyphen_suffix_after_variable',
        'Нельзя приклеивать падежные окончания к переменным через дефис (например, «{{3}}-ке»). Перестройте фразу («сағат {{3}} уақытында»).'
      )
    end

    positional_matches = serialized_body.scan(/\{\{(\d+)\}\}/).flatten.map(&:to_i)
    unique_numbers = positional_matches.uniq

    if positional_matches.size != unique_numbers.size
      add_error(errors, error_codes, 'duplicate_variables', 'Переменные в шаблоне не должны дублироваться.')
    end

    if unique_numbers.any?
      expected_sequence = (1..unique_numbers.size).to_a
      if unique_numbers != expected_sequence
        add_error(
          errors,
          error_codes,
          'non_sequential_variables',
          "Переменные должны нумероваться строго по порядку с {{1}} без пропусков (сейчас: #{unique_numbers.map { |n| "{{#{n}}}" }.join(', ')})."
        )
      end
    end

    if @expected_variables_count.present? && unique_numbers.size != @expected_variables_count.to_i
      add_error(
        errors,
        error_codes,
        'unexpected_variables_count',
        "Ожидалось переменных: #{@expected_variables_count.to_i}, найдено: #{unique_numbers.size}."
      )
    end

    if !@bilingual && normalized_lang == 'kk' && !KAZAKH_SPECIFIC_CHARS_REGEX.match?(@raw_body)
      add_error(
        errors,
        error_codes,
        'missing_kazakh_script',
        'Шаблон на казахском языке (kk) должен содержать текст на казахском языке.'
      )
    end

    validate_buttons(button_texts, errors, error_codes)

    build_result(
      errors,
      warnings,
      error_codes,
      serialized_body,
      unique_numbers.map(&:to_s),
      variable_keys
    )
  end

  private

  def add_error(errors, error_codes, code, message)
    error_codes << code unless error_codes.include?(code)
    errors << message unless errors.include?(message)
  end

  def extract_button_texts(buttons)
    Array(buttons).filter_map do |btn|
      case btn
      when String
        btn.strip
      when Hash, ActionController::Parameters
        h = btn.respond_to?(:to_unsafe_h) ? btn.to_unsafe_h : btn.to_h
        (h['text'] || h[:text]).to_s.strip
      end
    end
  end

  def validate_buttons(button_texts, errors, error_codes)
    if button_texts.length > MAX_QUICK_REPLY_BUTTONS
      add_error(
        errors,
        error_codes,
        'too_many_buttons',
        "Максимум #{MAX_QUICK_REPLY_BUTTONS} кнопки быстрого ответа."
      )
    end

    button_texts.each_with_index do |btn_text, idx|
      if btn_text.blank?
        add_error(errors, error_codes, 'empty_button_text', "Текст кнопки №#{idx + 1} не может быть пустым.")
      elsif btn_text.length > MAX_BUTTON_TEXT_LENGTH
        add_error(
          errors,
          error_codes,
          'button_text_too_long',
          "Кнопка «#{btn_text}» слишком длинная (#{btn_text.length} симв., максимум #{MAX_BUTTON_TEXT_LENGTH})."
        )
      end
    end

    normalized_btns = button_texts.select(&:present?).map(&:downcase)
    return unless normalized_btns.uniq.length != normalized_btns.length

    add_error(errors, error_codes, 'duplicate_buttons', 'Тексты кнопок не должны повторяться.')
  end

  def build_result(errors, warnings, error_codes, serialized_body, variables, variable_keys)
    Result.new(
      valid: errors.empty?,
      errors: errors,
      warnings: warnings,
      error_codes: error_codes,
      serialized_body: serialized_body,
      serialized_body_text: serialized_body,
      variables: variables,
      variable_keys: variable_keys,
      variables_count: variables.size
    )
  end
end
