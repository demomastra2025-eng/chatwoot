# frozen_string_literal: true

module Whatsapp::SupportedLanguages
  DEFAULT_CLIENT_LANGUAGES = %w[ru kk].freeze

  LANGUAGES = [
    { code: 'ru', name: 'Русский', native_name: 'Русский', english_name: 'Russian' },
    { code: 'kk', name: 'Казахский (Қазақша)', native_name: 'Қазақша', english_name: 'Kazakh' },
    { code: 'en', name: 'Английский (English)', native_name: 'English', english_name: 'English' },
    { code: 'uz', name: 'Узбекский (Oʻzbekcha)', native_name: 'Oʻzbekcha', english_name: 'Uzbek' },
    { code: 'ky', name: 'Кыргызский (Кыргызча)', native_name: 'Кыргызча', english_name: 'Kyrgyz' },
    { code: 'tr', name: 'Турецкий (Türkçe)', native_name: 'Türkçe', english_name: 'Turkish' },
    { code: 'az', name: 'Азербайджанский (Azərbaycan)', native_name: 'Azərbaycan', english_name: 'Azerbaijani' },
    { code: 'tg', name: 'Таджикский (Тоҷикӣ)', native_name: 'Тоҷикӣ', english_name: 'Tajik' },
    { code: 'uk', name: 'Украинский (Українська)', native_name: 'Українська', english_name: 'Ukrainian' },
    { code: 'de', name: 'Немецкий (Deutsch)', native_name: 'Deutsch', english_name: 'German' },
    { code: 'fr', name: 'Французский (Français)', native_name: 'Français', english_name: 'French' },
    { code: 'es', name: 'Испанский (Español)', native_name: 'Español', english_name: 'Spanish' },
    { code: 'pt_BR', name: 'Португальский (Português)', native_name: 'Português', english_name: 'Portuguese' },
    { code: 'ar', name: 'Арабский (العربية)', native_name: 'العربية', english_name: 'Arabic' },
    { code: 'zh_CN', name: 'Китайский (中文)', native_name: '中文', english_name: 'Chinese (Simplified)' },
    { code: 'ja', name: 'Японский (日本語)', native_name: '日本語', english_name: 'Japanese' },
    { code: 'ko', name: 'Корейский (한국어)', native_name: '한국어', english_name: 'Korean' },
    { code: 'hi', name: 'Хинди (हिन्दी)', native_name: 'हिन्दी', english_name: 'Hindi' },
    { code: 'it', name: 'Итальянский (Italiano)', native_name: 'Italiano', english_name: 'Italian' },
    { code: 'pl', name: 'Польский (Polski)', native_name: 'Polski', english_name: 'Polish' },
    { code: 'nl', name: 'Нидерландский (Nederlands)', native_name: 'Nederlands', english_name: 'Dutch' },
    { code: 'id', name: 'Индонезийский (Bahasa Indonesia)', native_name: 'Bahasa Indonesia', english_name: 'Indonesian' },
    { code: 'vi', name: 'Вьетнамский (Tiếng Việt)', native_name: 'Tiếng Việt', english_name: 'Vietnamese' },
    { code: 'th', name: 'Тайский (ไทย)', native_name: 'ไทย', english_name: 'Thai' },
    { code: 'he', name: 'Иврит (עברית)', native_name: 'עברית', english_name: 'Hebrew' },
    { code: 'fa', name: 'Персидский (فارسی)', native_name: 'فارسی', english_name: 'Persian' },
    { code: 'ur', name: 'Урду (اردو)', native_name: 'اردو', english_name: 'Urdu' },
    { code: 'ka', name: 'Грузинский (ქართული)', native_name: 'ქართული', english_name: 'Georgian' },
    { code: 'hy', name: 'Армянский (Հայերեն)', native_name: 'Հայերեն', english_name: 'Armenian' },
    { code: 'ro', name: 'Румынский (Română)', native_name: 'Română', english_name: 'Romanian' },
    { code: 'cs', name: 'Чешский (Čeština)', native_name: 'Čeština', english_name: 'Czech' },
    { code: 'el', name: 'Греческий (Ελληνικά)', native_name: 'Ελληνικά', english_name: 'Greek' },
    { code: 'sv', name: 'Шведский (Svenska)', native_name: 'Svenska', english_name: 'Swedish' },
    { code: 'hu', name: 'Венгерский (Magyar)', native_name: 'Magyar', english_name: 'Hungarian' },
    { code: 'bg', name: 'Болгарский (Български)', native_name: 'Български', english_name: 'Bulgarian' },
    { code: 'sr', name: 'Сербский (Српски)', native_name: 'Српски', english_name: 'Serbian' },
    { code: 'hr', name: 'Хорватский (Hrvatski)', native_name: 'Hrvatski', english_name: 'Croatian' },
    { code: 'sk', name: 'Словацкий (Slovenčina)', native_name: 'Slovenčina', english_name: 'Slovak' },
    { code: 'fi', name: 'Финский (Suomi)', native_name: 'Suomi', english_name: 'Finnish' },
    { code: 'da', name: 'Датский (Dansk)', native_name: 'Dansk', english_name: 'Danish' },
    { code: 'no', name: 'Норвежский (Norsk)', native_name: 'Norsk', english_name: 'Norwegian' },
    { code: 'ms', name: 'Малайский (Bahasa Melayu)', native_name: 'Bahasa Melayu', english_name: 'Malay' }
  ].freeze

  BY_CODE = LANGUAGES.index_by { |entry| entry[:code] }.freeze
  CODES = BY_CODE.keys.freeze

  ALIASES = {
    'kz' => 'kk',
    'kaz' => 'kk',
    'rus' => 'ru',
    'eng' => 'en',
    'en_us' => 'en',
    'en_gb' => 'en',
    'ru_ru' => 'ru',
    'kk_kz' => 'kk',
    'pt' => 'pt_BR',
    'pt_br' => 'pt_BR',
    'zh' => 'zh_CN',
    'zh_cn' => 'zh_CN',
    'ua' => 'uk',
    'iw' => 'he'
  }.freeze

  CODE_FORMAT = /\A[a-z]{2}(?:_[A-Z]{2})?\z/

  module_function

  def normalize_code(raw_code)
    cleaned = raw_code.to_s.strip.tr('-', '_')
    return nil if cleaned.blank?

    downcased = cleaned.downcase
    return ALIASES[downcased] if ALIASES.key?(downcased)

    exact = BY_CODE.keys.find { |code| code.casecmp?(cleaned) }
    return exact if exact

    parts = cleaned.split('_', 2)
    normalized = parts.length == 2 ? "#{parts[0].downcase}_#{parts[1].upcase}" : parts[0].downcase
    normalized if normalized.match?(CODE_FORMAT)
  end

  def valid_code?(raw_code)
    normalize_code(raw_code).present?
  end

  def normalize_list(raw_codes, fallback: DEFAULT_CLIENT_LANGUAGES)
    list = case raw_codes
           when String
             raw_codes.split(/[,\s]+/)
           when Array
             raw_codes
           else
             Array(raw_codes)
           end

    normalized = list.filter_map { |code| normalize_code(code) }.uniq
    normalized.presence || Array(fallback).filter_map { |code| normalize_code(code) }.uniq
  end

  def entry_for(raw_code)
    code = normalize_code(raw_code)
    return nil if code.blank?

    BY_CODE[code] || { code: code, name: code.upcase, native_name: code.upcase, english_name: code.upcase }
  end

  def name_for(raw_code)
    entry_for(raw_code)&.dig(:name)
  end

  def label_for(raw_code)
    name_for(raw_code)
  end

  def english_name_for(raw_code)
    entry_for(raw_code)&.dig(:english_name)
  end
end
