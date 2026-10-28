require 'rails_helper'

RSpec.describe Llm::OpenRouterAudioInput do
  it 'preserves both channels when converting unsupported stereo audio to WAV' do
    source = Tempfile.new(['stereo-call', '.aac'])
    source.write('fake audio')
    source.close
    destination = "#{source.path}.openrouter.wav"
    allow(described_class).to receive(:format_for).and_return('aac')
    allow(described_class).to receive(:ffmpeg_path).and_return('/usr/bin/ffmpeg')
    allow(Telephony::CallTranscript).to receive(:probe).with(source.path).and_return('channels' => 2)
    allow(Open3).to receive(:capture3) do |*args|
      expect(args.each_cons(2)).to include(['-ac', '2'])
      File.binwrite(destination, 'fake WAV')
      ['', '', instance_double(Process::Status, success?: true)]
    end

    expect(described_class.normalize_for_chat(source.path)).to eq(destination)
  ensure
    FileUtils.rm_f(destination) if defined?(destination)
    source&.close!
  end
end
