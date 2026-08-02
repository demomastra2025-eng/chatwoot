class Telephony::AiVoice::VoiceLanguageSettings
  DEFAULT_PRIORITIES = %w[ru-KZ kk-KZ en-US].freeze
  MAX_PRIORITIES = 4
  LANGUAGE_CODE_PATTERN = /\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z/

  def self.normalize!(settings, defaults)
    priorities = Array(settings['input_language_priorities']).filter_map do |value|
      code = value.to_s.strip
      code if code.match?(LANGUAGE_CODE_PATTERN)
    end.uniq.first(MAX_PRIORITIES)
    priorities = defaults['input_language_priorities'].dup if priorities.empty?

    primary_language = settings['language'].to_s
    if primary_language != 'auto' && primary_language.match?(LANGUAGE_CODE_PATTERN)
      priorities = [primary_language, *priorities.reject { |code| code == primary_language }]
    end

    settings['input_language_priorities'] = priorities.first(MAX_PRIORITIES)
  end
end
