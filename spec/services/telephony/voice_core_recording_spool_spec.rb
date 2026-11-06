require 'rails_helper'
require 'tmpdir'

RSpec.describe Telephony::VoiceCoreRecordingSpool do
  let(:account_id) { 101 }
  let(:key) { "voice-recordings/wazo/#{account_id}/synthetic/audio.wav" }
  let(:session) do
    instance_double(Telephony::CallSession, account_id: account_id, recording_ref: key, metadata: { 'recording' => { 'storage_key' => key } })
  end
  let(:service) { described_class.new(session) }
  let(:remote) { instance_double(ActiveStorage::Service) }
  let(:directory) { Dir.mktmpdir('voicecore-spool-spec-') }
  let(:spool_root) { File.join(directory, 'spool') }
  let(:source_path) { File.join(directory, 'synthetic.wav') }

  around do |example|
    File.binwrite(source_path, 'synthetic audio bytes')
    with_modified_env('ONELINK_VOICECORE_SPOOL_ROOT' => spool_root) { example.run }
  ensure
    FileUtils.remove_entry(directory)
  end

  before do
    allow(Storage::RecordingPaths).to receive(:resolve).with(key, account_id: account_id).and_return(Pathname.new(source_path))
    allow(Storage::VoiceRecordingRemoteStorage).to receive(:enabled?).and_return(true)
    allow(Storage::VoiceRecordingRemoteStorage).to receive(:active_storage_service).and_return(remote)
  end

  it 'copies unchanged bytes into a private tenant job and removes only its own copy' do
    staged = nil
    service.open do |spool|
      staged = File.join(spool_root, account_id.to_s, spool.job_id, spool.audio_filename)
      expect(File.binread(staged)).to eq('synthetic audio bytes')
      expect(File.stat(staged).mode & 0o777).to eq(0o600)
      expect(File.stat(File.dirname(staged)).mode & 0o777).to eq(0o700)
    end
    expect(File.exist?(staged)).to be(false)
    expect(File.binread(source_path)).to eq('synthetic audio bytes')
  end

  it 'cleans up the job on provider error' do
    expect do
      service.open { raise Telephony::VoiceCoreClient::Error, 'invalid_response' }
    end.to raise_error(Telephony::VoiceCoreClient::Error)
    expect(Dir.glob(File.join(spool_root, account_id.to_s, '*'))).to be_empty
  end

  it 'rejects a foreign tenant key before local lookup or remote download' do
    allow(session).to receive(:metadata).and_return('recording' => { 'storage_key' => 'voice-recordings/wazo/102/call/audio.wav' })
    expect { service.open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error)
    expect(Storage::RecordingPaths).not_to have_received(:resolve)
    expect(Storage::VoiceRecordingRemoteStorage).not_to have_received(:active_storage_service)
  end

  it 'streams remote bytes into the spool without a second unbounded download buffer' do
    allow(Storage::RecordingPaths).to receive(:resolve).and_return(nil)
    allow(remote).to receive(:exist?).with(key).and_return(true)
    allow(remote).to receive(:download).with(key).and_yield('first ').and_yield('second')
    service.open do |spool|
      expect(File.binread(File.join(spool_root, account_id.to_s, spool.job_id, spool.audio_filename))).to eq('first second')
    end
    expect(remote).to have_received(:download).with(key).once
  end

  it 'enforces the byte cap while streaming and removes the partial job' do
    stub_const('Telephony::VoiceCoreRecordingSpool::MAX_AUDIO_BYTES', 5)
    expect { service.open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error) do |error|
      expect(error.code).to eq('audio_too_large')
    end
    expect(Dir.glob(File.join(spool_root, account_id.to_s, '*'))).to be_empty
  end

  it 'rejects symlink spool roots without writing through them' do
    File.symlink(File.dirname(spool_root), spool_root)
    expect { service.open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error)
    expect(File.exist?(File.join(File.dirname(spool_root), account_id.to_s))).to be(false)
  end
end
