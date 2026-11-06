require 'rails_helper'
require 'tmpdir'

RSpec.describe Messages::VoiceCoreAttachmentSpool do
  let(:message) { instance_double(Message, account_id: 101) }
  let(:attachment) { instance_double(Attachment, account_id: 101, message: message, file: attached_file) }
  let(:attached_file) { instance_double(ActiveStorage::Attached::One, attached?: true, blob: blob) }
  let(:blob) do
    instance_double(ActiveStorage::Blob, content_type: 'audio/opus', filename: ActiveStorage::Filename.new('synthetic-upload-no-extension'))
  end
  let(:directory) { Dir.mktmpdir('voicecore-attachment-spec-') }
  let(:spool_root) { File.join(directory, 'spool') }

  around do |example|
    with_modified_env('ONELINK_VOICECORE_SPOOL_ROOT' => spool_root) { example.run }
  ensure
    FileUtils.remove_entry(directory)
  end

  before do
    allow(blob).to receive(:download).and_yield('OggS').and_yield('synthetic')
  end

  it 'streams a native blob into the shared private spool with only its canonical MIME extension' do
    staged = nil
    described_class.new(attachment).open do |spool|
      staged = File.join(spool_root, '101', spool.job_id, spool.audio_filename)
      expect(spool.audio_filename).to eq('audio.ogg')
      expect(File.binread(staged)).to eq('OggSsynthetic')
      expect(File.stat(staged).mode & 0o7777).to eq(0o600)
    end
    expect(File.exist?(staged)).to be(false)
    expect(blob).to have_received(:download).once
  end

  it 'rejects a foreign attachment account before downloading or staging bytes' do
    allow(attachment).to receive(:account_id).and_return(102)
    expect { described_class.new(attachment).open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error)
    expect(blob).not_to have_received(:download)
    expect(File.exist?(spool_root)).to be(false)
  end

  it 'enforces the same cumulative chunk limit and cleanup as call recordings' do
    stub_const('Telephony::VoiceCoreAudioSpool::MAX_AUDIO_BYTES', 5)
    expect { described_class.new(attachment).open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error) do |error|
      expect(error.code).to eq('audio_too_large')
    end
    expect(Dir.glob(File.join(spool_root, '101', '*'))).to be_empty
  end

  it 'preserves the native missing-blob exception for the existing job retry' do
    allow(blob).to receive(:download).and_raise(ActiveStorage::FileNotFoundError)
    expect { described_class.new(attachment).open { raise 'must not yield' } }.to raise_error(ActiveStorage::FileNotFoundError)
    expect(Dir.glob(File.join(spool_root, '101', '*'))).to be_empty
  end

  it 'rejects unsupported local formats before downloading rather than using a paid provider' do
    allow(blob).to receive(:content_type).and_return('text/plain')
    expect { described_class.new(attachment).open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error) do |error|
      expect(error.code).to eq('unsupported_audio')
    end
    expect(blob).not_to have_received(:download)
  end

  %w[aac webm].each do |extension|
    it "preserves native #{extension} voice note support using the same bounded private lifecycle" do
      allow(blob).to receive(:content_type).and_return("audio/#{extension}")
      described_class.new(attachment).open do |spool|
        expect(spool.audio_filename).to eq("audio.#{extension}")
        expect(File.binread(File.join(spool_root, '101', spool.job_id, spool.audio_filename))).to eq('OggSsynthetic')
      end
      expect(Dir.glob(File.join(spool_root, '101', '*'))).to be_empty
    end
  end
end
