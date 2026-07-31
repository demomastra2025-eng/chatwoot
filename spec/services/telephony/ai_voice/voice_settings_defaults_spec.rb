require 'rails_helper'

RSpec.describe Telephony::AiVoice::VoiceSettingsDefaults do
  describe '.normalize' do
    it 'keeps Gemini Live as the default provider' do
      expect(described_class.normalize({})).to include(
        'provider' => 'gemini-live',
        'model' => 'gemini-3.1-flash-live-preview',
        'voice' => 'sulafat',
        'language' => 'auto',
        'thinking_level' => 'minimal',
        'context_window_compression_enabled' => true,
        'proactive_audio_enabled' => false,
        'api_version' => 'v1beta'
      )
    end

    it 'normalizes manager handoff settings and keeps safe backward-compatible defaults' do
      expect(described_class.normalize({})).to include(
        'manager_handoff_mode' => 'live_transfer',
        'transfer_failure_mode' => 'continue',
        'silence_prompt_after_ms' => 5000,
        'second_silence_prompt_after_ms' => 12_000,
        'max_silence_ms' => 25_000
      )

      expect(
        described_class.normalize(
          manager_handoff_mode: 'unknown',
          transfer_failure_mode: 'unknown',
          callback_message: '',
          silence_prompt_after_ms: 15_000,
          second_silence_prompt_after_ms: 10_000,
          max_silence_ms: 5_000
        )
      ).to include(
        'manager_handoff_mode' => 'live_transfer',
        'transfer_failure_mode' => 'continue',
        'callback_message' => described_class::DEFAULTS.fetch('callback_message'),
        'silence_prompt_after_ms' => 5000,
        'second_silence_prompt_after_ms' => 12_000,
        'max_silence_ms' => 25_000
      )
    end

    it 'treats zero as a disabled silence stage and orders the remaining active stages' do
      expect(
        described_class.normalize(
          silence_prompt_after_ms: 0,
          second_silence_prompt_after_ms: 12_000,
          max_silence_ms: 25_000
        )
      ).to include(
        'silence_prompt_after_ms' => 0,
        'second_silence_prompt_after_ms' => 12_000,
        'max_silence_ms' => 25_000
      )
      expect(
        described_class.normalize(
          silence_prompt_after_ms: 15_000,
          second_silence_prompt_after_ms: 10_000,
          max_silence_ms: 0
        )
      ).to include(
        'silence_prompt_after_ms' => 5000,
        'second_silence_prompt_after_ms' => 12_000,
        'max_silence_ms' => 25_000
      )
      expect(
        described_class.normalize(
          silence_prompt_after_ms: 0,
          second_silence_prompt_after_ms: 0,
          max_silence_ms: 0
        )
      ).to include(
        'silence_prompt_after_ms' => 0,
        'second_silence_prompt_after_ms' => 0,
        'max_silence_ms' => 0
      )
    end

    it 'applies OpenAI Realtime defaults' do
      expect(described_class.normalize(provider: 'openai-realtime')).to include(
        'provider' => 'openai-realtime',
        'model' => 'gpt-realtime-2',
        'voice' => 'alloy',
        'language' => 'ru-KZ'
      )
    end

    it 'does not pass Gemini auto language to another provider' do
      expect(described_class.normalize(provider: 'openai-realtime', language: 'auto')).to include(
        'language' => 'ru-KZ'
      )
    end

    it 'does not pass auto language to a legacy Gemini model' do
      expect(described_class.normalize(model: 'gemini-2.0-flash-live-001', language: 'auto')).to include(
        'language' => 'ru-KZ'
      )
    end

    it 'falls back from an unknown Gemini thinking level' do
      expect(described_class.normalize(thinking_level: 'unknown')).to include(
        'thinking_level' => 'minimal'
      )
    end

    it 'uses the preview API only when proactive audio is enabled for a supported Gemini model' do
      expect(described_class.normalize(proactive_audio_enabled: true)).to include(
        'proactive_audio_enabled' => true,
        'api_version' => 'v1alpha'
      )
      expect(described_class.normalize(model: 'gemini-2.0-flash-live-001', proactive_audio_enabled: true)).to include(
        'proactive_audio_enabled' => false,
        'api_version' => 'v1beta'
      )
      expect(described_class.normalize(provider: 'openai-realtime', proactive_audio_enabled: true)).to include(
        'proactive_audio_enabled' => false
      )
    end

    it 'applies ElevenLabs and OpenRouter defaults to blank values' do
      expect(described_class.normalize(provider: 'elevenlabs', model: '', voice: nil)).to include(
        'provider' => 'elevenlabs',
        'model' => 'openai/gpt-5.4-mini',
        'voice' => 'Xb7hH8MSUJpSbSDYk0k2'
      )
    end

    it 'applies Cartesia and OpenRouter defaults to blank values' do
      expect(described_class.normalize(provider: 'cartesia', model: '', voice: nil)).to include(
        'provider' => 'cartesia',
        'model' => 'openai/gpt-5.4-mini',
        'voice' => '71a7ad14-091c-4e8e-a314-022ece01c121'
      )
    end
  end
end
