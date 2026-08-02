require 'rails_helper'

RSpec.describe Telephony::AiVoice::FishAudioClient do
  describe '#create_model' do
    it 'rejects requests when the provider key is missing' do
      upload = instance_double(
        ActionDispatch::Http::UploadedFile,
        tempfile: instance_double(Tempfile),
        content_type: 'audio/mpeg',
        original_filename: 'voice.mp3'
      )
      client = described_class.new(api_key: '', connection: instance_double(Faraday::Connection))

      expect do
        client.create_model(title: 'Voice', upload: upload)
      end.to raise_error(described_class::ConfigurationError, 'Fish Audio is not configured')
    end
  end

  describe 'provider key configuration' do
    it 'uses the canonical Pipecat Fish key in Rails' do
      with_modified_env(
        ONELINK_AI_VOICE_PIPECAT_FISH_API_KEY: 'canonical-fish-key',
        FISH_AUDIO_API_KEY: nil,
        FISH_API_KEY: nil
      ) do
        client = described_class.new(connection: instance_double(Faraday::Connection))

        expect(client.send(:api_key)).to eq('canonical-fish-key')
      end
    end
  end
end
