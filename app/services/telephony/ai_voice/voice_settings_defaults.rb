class Telephony::AiVoice::VoiceSettingsDefaults
  BOOLEAN = ActiveModel::Type::Boolean.new

  DEFAULTS = {
    'humanlike_defaults_profile' => 'standard_v1',
    'provider' => 'gemini-live',
    'model' => 'gemini-3.1-flash-live-preview',
    'api_version' => 'v1beta',
    'voice' => 'sulafat',
    'language' => 'ru-KZ',
    'thinking_level' => 'minimal',
    'context_window_compression_enabled' => true,
    'system_prompt' => '', 'voice_character_prompt' => '',
    'temperature' => 0.3,
    'max_output_tokens' => 1024,
    'max_duration_sec' => 900,
    'recording_enabled' => true, 'first_message' => 'Здравствуйте! Чем могу помочь?',
    'closing_message' => 'Спасибо за звонок. Хорошего дня!',
    'interruptions_enabled' => true,
    'interruption_mode' => 'transcript_confirmed',
    'clear_audio_on_interrupt' => true,
    'finish_current_word_on_interrupt' => true,
    'interrupt_word_boundary_grace_ms' => 120,
    'post_interrupt_micro_pause_ms' => 180,
    'interrupt_ack_enabled' => true,
    'interrupt_ack_phrases' => ['Ага.', 'Понял.', 'Мм.', 'Аха.', 'А-а, понял.'].freeze,
    'interrupt_ack_max_duration_ms' => 700,
    'turn_aggregation_delay_ms' => 400,
    'turn_coverage' => 'TURN_INCLUDES_ONLY_ACTIVITY',
    'post_interrupt_resume_delay_ms' => 250,
    'min_interrupt_words' => 1,
    'silence_prompt_enabled' => true,
    'end_call_on_silence_enabled' => true,
    'silence_prompt' => 'Вы ещё на линии? Могу подсказать варианты.',
    'second_silence_prompt' => 'Если удобно, скажите коротко: запись, статус заявки или оператор.',
    'final_silence_message' => 'Похоже, сейчас неудобно говорить. Я завершу звонок, вы сможете продолжить позже.',
    'filler_phrases' => ['Понял.', 'Да, вижу.', 'Сейчас уточню.'].freeze,
    'tool_start_phrases' => ['Секунду, проверю.'].freeze,
    'tool_start_after_ms' => 1800,
    'tool_foreground_wait_ms' => 900,
    'tool_delay_phrases' => ['Ещё смотрю, почти готово.'].freeze,
    'tool_failure_phrases' => ['Не получилось проверить автоматически. Могу соединить со специалистом.'].freeze,
    'tool_delay_after_ms' => 1800,
    'post_tool_continuation_ms' => 4000,
    'proactive_audio_enabled' => false,
    'affective_dialog_enabled' => false,
    'max_sentences' => 2,
    'emotional_style' => 'warm_professional',
    'emotional_intensity' => 'low',
    'natural_pause_enabled' => true,
    'natural_pause_ms' => [120, 450].freeze,
    'thinking_cue_enabled' => true,
    'thinking_cue_phrases' => ['Так...', 'Сейчас...', 'Мм, понял.'].freeze,
    'nonverbal_cues_enabled' => true,
    'nonverbal_cue_phrases' => ['Угу.', 'Мм.', 'Да.'].freeze,
    'nonverbal_cue_max_per_minute' => 1,
    'sigh_cues_enabled' => false,
    'sigh_cue_max_per_call' => 0,
    'ambient_noise_enabled' => false,
    'ambient_noise_profile' => 'office_room_tone',
    'ambient_noise_volume_dbfs' => -42,
    'ambient_noise_duck_on_caller_speech' => true,
    'ambient_noise_outbound_only' => true
  }.merge(Telephony::AiVoice::VoiceLifecycleSettings::DEFAULTS)
             .merge(Telephony::AiVoice::VoiceActivitySettings::DEFAULTS).freeze

  PROVIDER_DEFAULTS = {
    'gemini-live' => {
      'model' => 'gemini-3.1-flash-live-preview',
      'voice' => 'sulafat',
      'language' => 'auto'
    }.freeze,
    'openai-realtime' => {
      'model' => 'gpt-realtime-2',
      'voice' => 'alloy'
    }.freeze,
    'elevenlabs' => {
      'model' => 'openai/gpt-5.4-mini',
      'voice' => 'Xb7hH8MSUJpSbSDYk0k2'
    }.freeze,
    'cartesia' => {
      'model' => 'openai/gpt-5.4-mini',
      'voice' => '71a7ad14-091c-4e8e-a314-022ece01c121'
    }.freeze
  }.freeze

  BOOLEAN_KEYS = %w[
    interruptions_enabled clear_audio_on_interrupt finish_current_word_on_interrupt interrupt_ack_enabled
    silence_prompt_enabled end_call_on_silence_enabled proactive_audio_enabled affective_dialog_enabled
    context_window_compression_enabled
    natural_pause_enabled thinking_cue_enabled nonverbal_cues_enabled sigh_cues_enabled ambient_noise_enabled
    ambient_noise_duck_on_caller_speech ambient_noise_outbound_only recording_enabled
  ].freeze

  INTEGER_KEYS = %w[
    max_output_tokens max_duration_sec interrupt_word_boundary_grace_ms post_interrupt_micro_pause_ms
    interrupt_ack_max_duration_ms prefix_padding_ms silence_duration_ms turn_aggregation_delay_ms
    post_interrupt_resume_delay_ms min_interrupt_words silence_prompt_after_ms second_silence_prompt_after_ms
    max_silence_ms tool_delay_after_ms post_tool_continuation_ms max_sentences nonverbal_cue_max_per_minute
    sigh_cue_max_per_call
    tool_start_after_ms tool_foreground_wait_ms
  ].freeze

  FLOAT_KEYS = %w[temperature ambient_noise_volume_dbfs vad_confidence vad_min_volume].freeze
  GEMINI_AUTO_LANGUAGE_MODELS = %w[
    gemini-3.1-flash-live-preview gemini-2.5-flash-native-audio-preview-12-2025
  ].freeze
  GEMINI_PROACTIVE_AUDIO_MODELS = GEMINI_AUTO_LANGUAGE_MODELS
  THINKING_LEVELS = %w[minimal low medium high].freeze
  MAX_DURATION_SEC_RANGE = (1..7200)

  ARRAY_KEYS = %w[
    interrupt_ack_phrases filler_phrases tool_start_phrases tool_delay_phrases tool_failure_phrases
    natural_pause_ms thinking_cue_phrases nonverbal_cue_phrases
  ].freeze

  class << self
    def normalize(raw_settings = {})
      raw = (raw_settings.respond_to?(:to_h) ? raw_settings.to_h.deep_stringify_keys : {}).slice(*DEFAULTS.keys)
      provider = raw['provider'].presence || DEFAULTS['provider']
      defaults = DEFAULTS.merge(PROVIDER_DEFAULTS.fetch(provider, {}))
      normalized = defaults.merge(raw).each_with_object({}) do |(key, value), result|
        result[key] = normalize_value(key, value_or_default(key, value, defaults))
      end
      normalize_provider_specific_values!(normalized, provider, defaults)
      normalized
    end

    def defaults
      normalize({})
    end

    private

    def normalize_provider_specific_values!(normalized, provider, defaults)
      normalized['thinking_level'] = defaults['thinking_level'] unless THINKING_LEVELS.include?(normalized['thinking_level'])
      Telephony::AiVoice::VoiceLifecycleSettings.normalize!(normalized, defaults)
      Telephony::AiVoice::VoiceActivitySettings.normalize!(normalized)
      duration = normalized['max_duration_sec']
      normalized['max_duration_sec'] = defaults['max_duration_sec'] unless duration.is_a?(Integer) && MAX_DURATION_SEC_RANGE.cover?(duration)
      normalize_auto_language!(normalized, provider)
      normalize_proactive_audio!(normalized, provider)
    end

    def normalize_auto_language!(normalized, provider)
      return unless normalized['language'] == 'auto'
      return if gemini_model_supported?(provider, normalized['model'], GEMINI_AUTO_LANGUAGE_MODELS)

      normalized['language'] = DEFAULTS['language']
    end

    def normalize_proactive_audio!(normalized, provider)
      supported = gemini_model_supported?(provider, normalized['model'], GEMINI_PROACTIVE_AUDIO_MODELS)
      normalized['proactive_audio_enabled'] = false unless supported
      return unless provider == 'gemini-live'

      normalized['api_version'] = normalized['proactive_audio_enabled'] ? 'v1alpha' : 'v1beta'
    end

    def gemini_model_supported?(provider, model, models)
      provider == 'gemini-live' && models.include?(model)
    end

    def normalize_value(key, value)
      return BOOLEAN.cast(value) if BOOLEAN_KEYS.include?(key)
      return integer_value(value) if INTEGER_KEYS.include?(key)
      return float_value(value) if FLOAT_KEYS.include?(key)
      return array_value(value) if ARRAY_KEYS.include?(key)

      value
    end

    def value_or_default(key, value, defaults)
      return value unless defaults.key?(key)
      return defaults[key] if value.nil?
      return defaults[key] if value.is_a?(String) && value.strip.blank?

      value
    end

    def integer_value(value)
      return value if value.is_a?(Integer)

      value.to_s.match?(/\A-?\d+\z/) ? value.to_i : value
    end

    def float_value(value)
      return value if value.is_a?(Numeric)

      Float(value)
    rescue ArgumentError, TypeError
      value
    end

    def array_value(value)
      return value if value.is_a?(Array)
      return [] if value.blank?

      [value]
    end
  end
end
