require 'rails_helper'

RSpec.describe Telephony::AiVoice::VoiceSettingsDefaults do
  describe '.normalize' do
    it 'keeps Gemini Live as the default provider' do
      expect(described_class.normalize({})).to include(
        'provider' => 'gemini-live',
        'model' => 'gemini-3.1-flash-live-preview',
        'voice' => 'sulafat'
      )
    end

    it 'applies OpenAI Realtime defaults' do
      expect(described_class.normalize(provider: 'openai-realtime')).to include(
        'provider' => 'openai-realtime',
        'model' => 'gpt-realtime-2',
        'voice' => 'alloy'
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
