class Telephony::AiVoice::VoiceActivitySettings
  DEFAULT_PROFILE = 'balanced'.freeze
  PROFILES = {
    'sensitive' => {
      'speech_start_sensitivity' => 'START_SENSITIVITY_HIGH',
      'speech_end_sensitivity' => 'END_SENSITIVITY_HIGH',
      'prefix_padding_ms' => 120,
      'vad_start_confirmation_ms' => 50,
      'silence_duration_ms' => 200,
      'turn_aggregation_delay_ms' => 180,
      'vad_confidence' => 0.6,
      'vad_min_volume' => 0.45
    }.freeze,
    'balanced' => {
      'speech_start_sensitivity' => 'START_SENSITIVITY_LOW',
      'speech_end_sensitivity' => 'END_SENSITIVITY_HIGH',
      'prefix_padding_ms' => 200,
      'vad_start_confirmation_ms' => 100,
      'silence_duration_ms' => 250,
      'turn_aggregation_delay_ms' => 180,
      'vad_confidence' => 0.75,
      'vad_min_volume' => 0.6
    }.freeze,
    'noisy' => {
      'speech_start_sensitivity' => 'START_SENSITIVITY_LOW',
      'speech_end_sensitivity' => 'END_SENSITIVITY_LOW',
      'prefix_padding_ms' => 300,
      'vad_start_confirmation_ms' => 150,
      'silence_duration_ms' => 300,
      'turn_aggregation_delay_ms' => 180,
      'vad_confidence' => 0.85,
      'vad_min_volume' => 0.7
    }.freeze
  }.freeze
  PROFILE_SETTING_KEYS = PROFILES.values.flat_map(&:keys).uniq.freeze
  DEFAULTS = {
    'voice_activity_profile' => DEFAULT_PROFILE,
    **PROFILES.fetch(DEFAULT_PROFILE)
  }.freeze

  class << self
    def normalize!(normalized, explicit_keys: [])
      explicit_profile_settings = normalized.slice(*(PROFILE_SETTING_KEYS & explicit_keys))
      profile = normalized['voice_activity_profile']
      profile = DEFAULT_PROFILE unless PROFILES.key?(profile)

      normalized['voice_activity_profile'] = profile
      normalized.merge!(PROFILES.fetch(profile))
      normalized.merge!(explicit_profile_settings) unless explicit_keys.include?('voice_activity_profile')
    end
  end
end
