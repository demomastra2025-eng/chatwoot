class Telephony::AiVoice::VoiceActivitySettings
  DEFAULT_PROFILE = 'balanced'.freeze
  PROFILES = {
    'sensitive' => {
      'speech_start_sensitivity' => 'START_SENSITIVITY_HIGH',
      'speech_end_sensitivity' => 'END_SENSITIVITY_HIGH',
      'prefix_padding_ms' => 120,
      'silence_duration_ms' => 300,
      'vad_confidence' => 0.6,
      'vad_min_volume' => 0.45
    }.freeze,
    'balanced' => {
      'speech_start_sensitivity' => 'START_SENSITIVITY_LOW',
      'speech_end_sensitivity' => 'END_SENSITIVITY_HIGH',
      'prefix_padding_ms' => 200,
      'silence_duration_ms' => 500,
      'vad_confidence' => 0.75,
      'vad_min_volume' => 0.6
    }.freeze,
    'noisy' => {
      'speech_start_sensitivity' => 'START_SENSITIVITY_LOW',
      'speech_end_sensitivity' => 'END_SENSITIVITY_LOW',
      'prefix_padding_ms' => 300,
      'silence_duration_ms' => 800,
      'vad_confidence' => 0.85,
      'vad_min_volume' => 0.7
    }.freeze
  }.freeze
  DEFAULTS = {
    'voice_activity_profile' => DEFAULT_PROFILE,
    **PROFILES.fetch(DEFAULT_PROFILE)
  }.freeze

  class << self
    def normalize!(normalized)
      profile = normalized['voice_activity_profile']
      profile = DEFAULT_PROFILE unless PROFILES.key?(profile)

      normalized['voice_activity_profile'] = profile
      normalized.merge!(PROFILES.fetch(profile))
    end
  end
end
