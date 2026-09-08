# frozen_string_literal: true

class Captain::FollowUpLanguageResolver
  DEFAULT_LANGUAGE = 'ru'
  LANGUAGE_ALIASES = {
    'kk-kz' => 'kk',
    'kz' => 'kk',
    'ru-ru' => 'ru',
    'ru-kz' => 'ru',
    'en-us' => 'en',
    'en-gb' => 'en'
  }.freeze

  pattr_initialize [:conversation!, :assistant!]

  def call
    candidates.filter_map { |value| normalize(value) }.first || DEFAULT_LANGUAGE
  end

  private

  def candidates
    [
      latest_message_language,
      conversation.language,
      conversation.contact&.additional_attributes.to_h['language_code'],
      conversation.contact&.custom_attributes.to_h['language_code'],
      assistant.account.locale,
      I18n.default_locale
    ]
  end

  def latest_message_language
    text = conversation.messages.incoming.where(private: false).order(created_at: :desc, id: :desc).limit(20).pluck(:content).find do |content|
      content.to_s.gsub(%r{https?://\S+}, '').scan(/\p{L}/).length >= 12
    end
    return if text.blank?

    result = CLD3::NNetLanguageIdentifier.new(0, 1000).find_language(text)
    result.language if result&.reliable?
  rescue StandardError
    nil
  end

  def normalize(value)
    normalized = value.to_s.strip.downcase.tr('_', '-')
    return if normalized.blank?

    LANGUAGE_ALIASES[normalized] || normalized.split('-').first.presence
  end
end
