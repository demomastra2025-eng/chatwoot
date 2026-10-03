# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'
require 'open3'

RSpec.describe Telephony::RecordingCompressionService do
  let(:account) { create(:account) }
  let(:storage_dir) { Rails.root.join('storage/voice-recordings/test_suite') }

  after do
    FileUtils.rm_rf(storage_dir)
  end

  describe '#perform' do
    it 'skips compression when storage_key is blank' do
      result = described_class.compress(storage_key: '')
      expect(result[:skipped]).to be(true)
      expect(result[:reason]).to eq(:blank_storage_key)
    end

    it 'skips compression when file does not exist' do
      result = described_class.compress(storage_key: 'voice-recordings/non_existent_file_xyz.wav')
      expect(result[:skipped]).to be(true)
      expect(result[:reason]).to eq(:file_not_found)
    end

    it 'skips compression when file is already MP3' do
      FileUtils.mkdir_p(storage_dir)
      mp3_file = storage_dir.join('already_compressed.mp3')
      File.write(mp3_file, 'dummy mp3 data')

      result = described_class.compress(storage_key: 'voice-recordings/test_suite/already_compressed.mp3')
      expect(result[:skipped]).to be(true)
      expect(result[:reason]).to eq(:already_mp3)
    end

    it 'compresses a valid WAV file to MP3 and updates CallSession' do
      FileUtils.mkdir_p(storage_dir)
      wav_path = storage_dir.join('sample_call.wav')
      Open3.capture3('ffmpeg', '-y', '-f', 'lavfi', '-i', 'sine=frequency=1000:duration=2', '-ar', '48000', wav_path.to_s)

      call_session = create(
        :telephony_call_session,
        account: account,
        recording_ref: 'voice-recordings/test_suite/sample_call.wav',
        metadata: { 'recording' => { 'storage_key' => 'voice-recordings/test_suite/sample_call.wav' } }
      )

      result = described_class.compress!(call_session: call_session)

      expect(result).to include(success: true, new_storage_key: 'voice-recordings/test_suite/sample_call.mp3')
      expect(result[:freed_bytes]).to be > 0
      expect(File.exist?(storage_dir.join('sample_call.mp3'))).to be(true)
      expect(File.exist?(wav_path)).to be(false)

      call_session.reload
      expect(call_session.recording_ref).to eq('voice-recordings/test_suite/sample_call.mp3')
      expect(call_session.metadata['recording']).to include('compressed' => true, 'codec' => 'mp3_48k')
    end
  end
end
