require 'rails_helper'

RSpec.describe Llm::OpenRouterAudioInput do
  before do
    allow(described_class).to receive(:format_for).and_return('unsupported')
    allow(described_class).to receive(:ffmpeg_path).and_return('ffmpeg')
  end

  it 'does not log ffmpeg stderr or the recording path when conversion fails' do
    Tempfile.create(['audio-private-recording-', '.unknown'], Rails.root.join('tmp')) do |file|
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(['', "ffmpeg failed: #{file.path}", status])
      expect(Rails.logger).not_to receive(:warn)
      expect(Rails.logger).not_to receive(:info)

      expect { described_class.normalize_for_transcription(file.path) }
        .to raise_error(described_class::NormalizationError, 'Audio transcription normalization failed')
    end
  end

  it 'does not log the recording path after successful conversion' do
    Tempfile.create(['audio-private-recording-', '.unknown'], Rails.root.join('tmp')) do |file|
      destination = "#{file.path}.openrouter.wav"
      File.binwrite(destination, 'RIFF')
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).and_return(['', '', status])
      expect(Rails.logger).not_to receive(:info)
      expect(Rails.logger).not_to receive(:warn)

      expect(described_class.normalize_for_transcription(file.path)).to eq(destination)
    ensure
      FileUtils.rm_f(destination)
    end
  end
end
