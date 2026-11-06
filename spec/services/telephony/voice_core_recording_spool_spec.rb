require 'rails_helper'
require 'tmpdir'
require 'timeout'

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
    stub_const('Telephony::VoiceCoreAudioSpool::MAX_AUDIO_BYTES', 5)
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

  private_modes = [0o750, 0o770, 0o707]
  %w[root account].each do |boundary|
    private_modes.each do |mode|
      it "rejects #{boundary} permissions #{mode.to_s(8)} without changing them or copying bytes" do
        FileUtils.mkdir_p(spool_root, mode: 0o700)
        target = boundary == 'root' ? spool_root : File.join(spool_root, account_id.to_s)
        Dir.mkdir(target, 0o700) unless target == spool_root
        File.chmod(mode, target)

        expect { service.open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error)
        expect(File.stat(target).mode & 0o7777).to eq(mode)
        expect(Storage::RecordingPaths).not_to have_received(:resolve)
      end
    end

    it "rejects a foreign-owned #{boundary} even when mode and path identities otherwise agree" do
      FileUtils.mkdir_p(spool_root, mode: 0o700)
      target = boundary == 'root' ? spool_root : File.join(spool_root, account_id.to_s)
      Dir.mkdir(target, 0o700) unless target == spool_root
      foreign_stat = File.lstat(target).dup
      allow(foreign_stat).to receive(:uid).and_return(Process.uid + 1)
      allow(File).to receive(:lstat).and_call_original
      allow(File).to receive(:lstat).with(Pathname.new(target)).and_return(foreign_stat)
      allow(File).to receive(:open).and_wrap_original do |original, *args, &block|
        result = original.call(*args, &block)
        allow(result).to receive(:stat).and_return(foreign_stat) if File.realpath(args.first.to_s) == target
        result
      end

      expect { service.open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error)
      expect(Storage::RecordingPaths).not_to have_received(:resolve)
      expect(Dir.children(target)).to be_empty
    end
  end

  %w[root account job].each do |boundary|
    it "refuses a replaced #{boundary} inode and preserves both replacement and displaced original" do
      staged = nil
      original = nil
      expect do
        service.open do |spool|
          staged = File.join(spool_root, account_id.to_s, spool.job_id, spool.audio_filename)
          target = { 'root' => spool_root, 'account' => File.dirname(staged, 2), 'job' => File.dirname(staged) }.fetch(boundary)
          File.rename(target, "#{target}-original")
          original = staged.sub(target, "#{target}-original")
          FileUtils.mkdir_p(File.dirname(staged), mode: 0o700)
          File.binwrite(staged, 'replacement sentinel')
        end
      end.to raise_error(Telephony::VoiceCoreClient::Error) { |error| expect(error.code).to eq('unsafe_spool') }
      expect(File.binread(staged)).to eq('replacement sentinel')
      expect(File.binread(original)).to eq('synthetic audio bytes')
    end
  end

  it 'refuses a replaced file inode without deleting either file' do
    staged = nil
    expect do
      service.open do |spool|
        staged = File.join(spool_root, account_id.to_s, spool.job_id, spool.audio_filename)
        File.rename(staged, "#{staged}-original")
        File.open(staged, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write('replacement sentinel') }
      end
    end.to raise_error(Telephony::VoiceCoreClient::Error)
    expect(File.binread(staged)).to eq('replacement sentinel')
    expect(File.binread("#{staged}-original")).to eq('synthetic audio bytes')
  end

  it 'does not follow a parent replaced with a symlink during cleanup' do
    staged = nil
    foreign = File.join(directory, 'foreign')
    expect do
      service.open do |spool|
        staged = File.join(spool_root, account_id.to_s, spool.job_id, spool.audio_filename)
        File.rename(spool_root, "#{spool_root}-original")
        FileUtils.mkdir_p(File.join(foreign, account_id.to_s, spool.job_id), mode: 0o700)
        File.binwrite(File.join(foreign, account_id.to_s, spool.job_id, spool.audio_filename), 'foreign sentinel')
        File.symlink(foreign, spool_root)
      end
    end.to raise_error(Telephony::VoiceCoreClient::Error)
    expect(File.symlink?(spool_root)).to be(true)
    expect(File.binread(staged)).to eq('foreign sentinel')
  end

  it 'does not unlink a substituted file symlink or its foreign target' do
    staged = nil
    foreign = File.join(directory, 'foreign.wav')
    File.binwrite(foreign, 'foreign sentinel')
    expect do
      service.open do |spool|
        staged = File.join(spool_root, account_id.to_s, spool.job_id, spool.audio_filename)
        File.rename(staged, "#{staged}-original")
        File.symlink(foreign, staged)
      end
    end.to raise_error(Telephony::VoiceCoreClient::Error)
    expect(File.symlink?(staged)).to be(true)
    expect(File.binread(foreign)).to eq('foreign sentinel')
    expect(File.binread("#{staged}-original")).to eq('synthetic audio bytes')
  end

  it 'refuses changed staged file permissions and skips cleanup rather than changing them' do
    staged = nil
    expect do
      service.open do |spool|
        staged = File.join(spool_root, account_id.to_s, spool.job_id, spool.audio_filename)
        File.chmod(0o644, staged)
      end
    end.to raise_error(Telephony::VoiceCoreClient::Error)
    expect(File.binread(staged)).to eq('synthetic audio bytes')
    expect(File.stat(staged).mode & 0o7777).to eq(0o644)
  end

  it 'enforces the cumulative remote byte limit and cleans up its own partial file' do
    stub_const('Telephony::VoiceCoreAudioSpool::MAX_AUDIO_BYTES', 5)
    allow(Storage::RecordingPaths).to receive(:resolve).and_return(nil)
    allow(remote).to receive(:exist?).with(key).and_return(true)
    allow(remote).to receive(:download).with(key).and_yield('one').and_yield('two')

    expect { service.open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error) do |error|
      expect(error.code).to eq('audio_too_large')
    end
    expect(Dir.glob(File.join(spool_root, account_id.to_s, '*'))).to be_empty
  end

  it 'checks boundaries again before writing a newly arrived remote chunk' do
    allow(Storage::RecordingPaths).to receive(:resolve).and_return(nil)
    allow(remote).to receive(:exist?).with(key).and_return(true)
    staged = nil
    allow(remote).to receive(:download) do |_key, &block|
      staged = Dir.glob(File.join(spool_root, account_id.to_s, '*', 'audio.wav')).fetch(0)
      File.rename(File.dirname(staged), "#{File.dirname(staged)}-original")
      Dir.mkdir(File.dirname(staged), 0o700)
      File.binwrite(staged, 'replacement sentinel')
      block.call('must not be written')
    end

    expect { service.open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error)
    expect(File.binread(staged)).to eq('replacement sentinel')
    expect(File.size(staged.sub(File.dirname(staged), "#{File.dirname(staged)}-original"))).to eq(0)
  end

  %w[root account].each do |boundary|
    it "rejects a FIFO #{boundary} without waiting for a writer or touching audio" do
      target = spool_root
      if boundary == 'account'
        Dir.mkdir(spool_root, 0o700)
        target = File.join(spool_root, account_id.to_s)
      end
      File.mkfifo(target, 0o600)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        Timeout.timeout(1) { service.open { raise 'must not yield' } }
      end.to raise_error(Telephony::VoiceCoreClient::Error)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
      expect(Storage::RecordingPaths).not_to have_received(:resolve)
      expect(Storage::VoiceRecordingRemoteStorage).not_to have_received(:active_storage_service)
    end
  end

  it 'anchors unlink to the held job directory when a writable ancestor swaps at the actual unlink boundary' do
    File.chmod(0o777, directory)
    staged = nil
    swapped = false
    allow(File).to receive(:unlink).and_wrap_original do |original, path|
      if !swapped && File.basename(path) == 'audio.wav'
        swapped = true
        File.rename(spool_root, "#{spool_root}-original")
        FileUtils.mkdir_p(File.dirname(staged), mode: 0o700)
        File.binwrite(staged, 'foreign sentinel')
      end
      original.call(path)
    end

    service.open { |spool| staged = File.join(spool_root, account_id.to_s, spool.job_id, spool.audio_filename) }
    expect(swapped).to be(true)
    expect(File.binread(staged)).to eq('foreign sentinel')
    expect(File.exist?(staged.sub(spool_root, "#{spool_root}-original"))).to be(false)
  end

  it 'anchors file creation when a parent swaps immediately before the actual file open' do
    staged = nil
    swapped = false
    allow(File).to receive(:open).and_wrap_original do |original, *args, &block|
      if !swapped && File.basename(args.first) == 'audio.wav' && args[1].is_a?(Integer) && args[1].anybits?(File::WRONLY)
        swapped = true
        staged = File.join(Dir.glob(File.join(spool_root, account_id.to_s, '*')).fetch(0), 'audio.wav')
        File.rename(spool_root, "#{spool_root}-original")
        FileUtils.mkdir_p(File.dirname(staged), mode: 0o700)
      end
      original.call(*args, &block)
    end

    expect { service.open { raise 'must not yield' } }.to raise_error(Telephony::VoiceCoreClient::Error)
    expect(swapped).to be(true)
    expect(File.exist?(staged)).to be(false)
    expect(File.size(staged.sub(spool_root, "#{spool_root}-original"))).to eq(0)
  end

  it 'anchors rmdir to the held account directory when its parent swaps at the actual rmdir boundary' do
    staged = nil
    job = nil
    swapped = false
    allow(Dir).to receive(:rmdir).and_wrap_original do |original, path|
      if !swapped && File.basename(path) == job
        swapped = true
        File.rename(spool_root, "#{spool_root}-original")
        FileUtils.mkdir_p(File.dirname(staged), mode: 0o700)
        File.binwrite(File.join(spool_root, 'foreign-sentinel'), 'preserve')
      end
      original.call(path)
    end

    service.open do |spool|
      job = spool.job_id
      staged = File.join(spool_root, account_id.to_s, job, spool.audio_filename)
    end
    expect(swapped).to be(true)
    expect(File.directory?(File.dirname(staged))).to be(true)
    expect(File.binread(File.join(spool_root, 'foreign-sentinel'))).to eq('preserve')
    expect(File.exist?(File.dirname(staged).sub(spool_root, "#{spool_root}-original"))).to be(false)
  end
end
