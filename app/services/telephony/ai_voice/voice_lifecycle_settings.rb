class Telephony::AiVoice::VoiceLifecycleSettings
  DEFAULTS = {
    'manager_handoff_mode' => 'live_transfer',
    'callback_message' => 'Спасибо, я передам информацию. Наш менеджер вам перезвонит.',
    'transfer_message' => 'Сейчас соединю вас со специалистом.',
    'transfer_failure_mode' => 'continue',
    'transfer_failure_message' => 'Не удалось соединить со специалистом. Наш менеджер вам перезвонит.',
    'silence_prompt_after_ms' => 5000,
    'second_silence_prompt_after_ms' => 12_000,
    'max_silence_ms' => 25_000
  }.freeze
  MANAGER_HANDOFF_MODES = %w[live_transfer callback disabled].freeze
  TRANSFER_FAILURE_MODES = %w[callback continue end_call].freeze
  SILENCE_THRESHOLD_KEYS = %w[silence_prompt_after_ms second_silence_prompt_after_ms max_silence_ms].freeze

  class << self
    def normalize!(normalized, defaults)
      normalize_option!(normalized, defaults, 'manager_handoff_mode', MANAGER_HANDOFF_MODES)
      normalize_option!(normalized, defaults, 'transfer_failure_mode', TRANSFER_FAILURE_MODES)
      normalize_silence_thresholds!(normalized, defaults)
    end

    private

    def normalize_option!(normalized, defaults, key, options)
      normalized[key] = defaults[key] unless options.include?(normalized[key])
    end

    def normalize_silence_thresholds!(normalized, defaults)
      values = SILENCE_THRESHOLD_KEYS.map { |key| normalized[key] }
      return if valid_silence_thresholds?(values)

      SILENCE_THRESHOLD_KEYS.each { |key| normalized[key] = defaults[key] }
    end

    def valid_silence_thresholds?(values)
      return false unless values.all? { |value| valid_silence_threshold?(value) }

      values.reject(&:zero?).each_cons(2).all? { |left, right| left < right }
    end

    def valid_silence_threshold?(value)
      value.is_a?(Integer) && value.between?(0, 3_600_000)
    end
  end
end
