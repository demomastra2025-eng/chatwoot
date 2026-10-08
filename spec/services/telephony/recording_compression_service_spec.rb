# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'
require 'open3'

RSpec.describe Telephony::RecordingCompressionService do
  include_context 'with isolated recording storage'

  let(:account) { create(:account) }
  let(:storage_dir) { Storage::RecordingPaths.root.join('voice-recordings/test_suite', account.id.to_s) }

  describe '#perform' do
    it 'logs only identifiers, a key digest, and the exception class on failure' do
      key = "voice-recordings/test_suite/#{account.id}/private-call-reference.wav"
      session = create(:telephony_call_session, account: account, recording_ref: key)
      service = described_class.new(call_session: session)
      allow(service).to receive(:perform!).and_raise(described_class::CompressionError, "private ffmpeg stderr #{key}")
      allow(Rails.logger).to receive(:warn)

      expect(service.perform).to include(success: false, error: 'Telephony::RecordingCompressionService::CompressionError')
      expect(Rails.logger).to have_received(:warn) do |warning|
        expect(warning).to include("account=#{account.id}", "session=#{session.id}",
                                   "key_digest=#{Digest::SHA256.hexdigest(key).first(12)}", 'CompressionError')
        expect(warning).not_to include(key, 'private ffmpeg stderr')
      end
    end

    it 'skips compression when storage_key is blank' do
      result = described_class.compress(storage_key: '')
      expect(result[:skipped]).to be(true)
      expect(result[:reason]).to eq(:blank_storage_key)
    end

    it 'skips compression when file does not exist for a persisted call' do
      key = "voice-recordings/test_suite/#{account.id}/missing.wav"
      session = create(:telephony_call_session, account: account, recording_ref: key)

      result = described_class.compress(call_session: session)

      expect(result[:skipped]).to be(true)
      expect(result[:reason]).to eq(:file_not_found)
    end

    it 'skips compression when file is already MP3' do
      FileUtils.mkdir_p(storage_dir)
      mp3_file = storage_dir.join('already_compressed.mp3')
      File.write(mp3_file, 'dummy mp3 data')

      key = "voice-recordings/test_suite/#{account.id}/already_compressed.mp3"
      session = create(:telephony_call_session, account: account, recording_ref: key)

      result = described_class.compress(call_session: session)
      expect(result[:skipped]).to be(true)
      expect(result[:reason]).to eq(:already_mp3)
    end

    it 'refuses to switch a recording without a persisted call session' do
      FileUtils.mkdir_p(storage_dir)
      wav_path = storage_dir.join('unowned.wav')
      _stdout, stderr, source_status = Open3.capture3(
        'ffmpeg', '-nostdin', '-y', '-f', 'lavfi', '-i', 'sine=frequency=900:duration=1',
        '-ac', '2', '-ar', '48000', wav_path.to_s
      )
      expect(source_status).to be_success, stderr

      result = described_class.compress(storage_key: "voice-recordings/test_suite/#{account.id}/unowned.wav")

      expect(result).to include(success: false)
      expect(File.exist?(wav_path)).to be(true)
      expect(File.exist?(storage_dir.join('unowned.mp3'))).to be(false)
    end

    it 'compresses a valid WAV file to MP3 and updates CallSession' do
      FileUtils.mkdir_p(storage_dir)
      wav_path = storage_dir.join('sample_call.wav')
      _stdout, stderr, source_status = Open3.capture3('ffmpeg', '-nostdin', '-y', '-f', 'lavfi', '-i', 'sine=frequency=1000:duration=2', '-ac', '2',
                                                      '-ar', '48000', wav_path.to_s)
      expect(source_status).to be_success, stderr

      call_session = create(
        :telephony_call_session,
        account: account,
        recording_ref: "voice-recordings/test_suite/#{account.id}/sample_call.wav",
        metadata: { 'recording' => { 'storage_key' => "voice-recordings/test_suite/#{account.id}/sample_call.wav" } }
      )

      result = described_class.compress!(call_session: call_session)

      expect(result).to include(success: true, new_storage_key: "voice-recordings/test_suite/#{account.id}/sample_call.mp3")
      expect(result[:freed_bytes]).to eq(0)
      expect(result[:retained_original_bytes]).to be > 0
      expect(File.exist?(storage_dir.join('sample_call.mp3'))).to be(true)
      expect(File.exist?(wav_path)).to be(true)

      call_session.reload
      expect(call_session.recording_ref).to eq("voice-recordings/test_suite/#{account.id}/sample_call.mp3")
      expect(call_session.metadata['recording']).to include('compressed' => true, 'codec' => 'mp3_64k')
      expect(call_session.metadata.dig('recording', 'retained_original',
                                       'storage_key')).to eq("voice-recordings/test_suite/#{account.id}/sample_call.wav")
      expect(call_session.metadata.dig('recording', 'retained_original', 'expires_at')).to be_present

      comp_file = storage_dir.join('sample_call.mp3')
      probe_cmd = [
        'ffprobe', '-v', 'error',
        '-select_streams', 'a:0',
        '-show_entries', 'stream=channels',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        comp_file.to_s
      ]
      channels, = Open3.capture3(*probe_cmd)
      expect(channels.strip).to eq('2')

      duration_cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1']
      input_duration, = Open3.capture3(*duration_cmd, wav_path.to_s)
      output_duration, = Open3.capture3(*duration_cmd, comp_file.to_s)
      expect((Float(output_duration) - Float(input_duration)).abs).to be <= 1.0
      _decode_out, decode_error, decode_status = Open3.capture3('ffmpeg', '-nostdin', '-v', 'error', '-i', comp_file.to_s, '-f', 'null', '-')
      expect(decode_status).to be_success, decode_error
    end

    context 'with a real WAV recording' do
      let(:wav_path) { storage_dir.join('call.wav') }
      let(:key) { "voice-recordings/test_suite/#{account.id}/call.wav" }
      let(:call_session) do
        create(:telephony_call_session, account: account, recording_ref: key,
                                        metadata: { 'recording' => { 'storage_key' => key, 'content_type' => 'audio/wav' } })
      end

      before do
        FileUtils.mkdir_p(storage_dir)
        _stdout, stderr, source_status = Open3.capture3('ffmpeg', '-nostdin', '-y', '-f', 'lavfi', '-i', 'sine=frequency=800:duration=2', '-ac', '2',
                                                        '-ar', '16000', wav_path.to_s)
        raise "Unable to create synthetic WAV fixture: #{stderr}" unless source_status.success?
      end

      it 'labels the compressed recording as MP3 so playback does not serve it as WAV' do
        described_class.compress!(call_session: call_session)

        expect(call_session.reload.metadata['recording']).to include('content_type' => 'audio/mpeg', 'compressed' => true)
      end

      it 'rewrites a qualified top-level conversation storage key after compression' do
        conversation = call_session.conversation
        conversation.update!(additional_attributes: { 'storage_key' => key, 'keep' => true })

        described_class.compress!(call_session: call_session)

        expect(conversation.reload.additional_attributes['storage_key']).to eq(key.sub('.wav', '.mp3'))
        expect(conversation.additional_attributes['keep']).to be(true)
        expect(File.exist?(wav_path)).to be(true)
      end

      it 'does not overwrite or remove an MP3 already published at the target path' do
        target = storage_dir.join('call.mp3')
        File.write(target, 'another worker live file')

        result = described_class.compress(call_session: call_session)

        expect(result).to include(success: false)
        expect(File.read(target)).to eq('another worker live file')
        expect(File.exist?(wav_path)).to be(true)
        expect(call_session.reload.recording_ref).to eq(key)
      end

      it 'is idempotent when a duplicate ready callback runs after the first conversion' do
        first_result = described_class.compress!(call_session: call_session)
        second_result = described_class.compress!(call_session: call_session.reload)

        expect(first_result[:success]).to be(true)
        expect(second_result).to include(skipped: true, reason: :already_mp3)
        expect(File.exist?(storage_dir.join('call.mp3'))).to be(true)
        expect(call_session.reload.recording_ref).to eq(key.sub('.wav', '.mp3'))
      end

      it 'keeps the original and leaves the call untouched when the database update fails' do
        session = call_session
        allow_any_instance_of(Telephony::CallSession).to receive(:save!).and_raise(ActiveRecord::StatementInvalid, 'boom') # rubocop:disable RSpec/AnyInstance

        result = described_class.compress(call_session: session)

        expect(result).to include(success: false)
        expect(File.exist?(wav_path)).to be(true)
        expect(File.exist?(storage_dir.join('call.mp3'))).to be(false)
        expect(call_session.reload.recording_ref).to eq(key)
        expect(call_session.metadata['recording']['content_type']).to eq('audio/wav')
      end

      it 'rewrites only the messages that reference the recording, without firing message events' do
        conversation = call_session.conversation
        mentioned = create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                                     content_attributes: { 'data' => { 'recording_ref' => wav_path.to_s, 'storage_key' => key, 'recording' => { 'storage_key' => key }, 'transcript' => 'preserve me' }, 'other' => { 'keep' => true } })
        legacy = create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                                 content_attributes: { 'data' => { 'recording_ref' => 'call.wav', 'transcript' => 'legacy transcript' } })
        conversation.update!(
          additional_attributes: { 'recording' => { 'storage_key' => 'call.wav' }, 'keep' => true }
        )
        collision_path = Storage::RecordingPaths.root.join('voice-recordings/provider-two', account.id.to_s, 'call.wav')
        FileUtils.mkdir_p(collision_path.dirname)
        File.write(collision_path, 'other provider recording')
        unrelated = create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                                     content_attributes: { 'data' => { 'recording' => { 'storage_key' => "voice-recordings/provider-two/#{account.id}/call.wav" } } })
        unrelated_conversation = create(:conversation, account: account, inbox: conversation.inbox,
                                                        additional_attributes: { 'recording' => { 'recording_ref' => "voice-recordings/provider-two/#{account.id}/call.wav" } })
        dispatcher = Rails.configuration.dispatcher
        allow(dispatcher).to receive(:dispatch).and_call_original

        described_class.compress!(call_session: call_session)

        expect(mentioned.reload.content_attributes['data']).to include('recording_ref' => "voice-recordings/test_suite/#{account.id}/call.mp3")
        expect(mentioned.content_attributes.dig('data', 'storage_key')).to eq("voice-recordings/test_suite/#{account.id}/call.mp3")
        expect(mentioned.content_attributes.dig('data', 'recording', 'storage_key')).to eq("voice-recordings/test_suite/#{account.id}/call.mp3")
        expect(legacy.reload.content_attributes.dig('data', 'recording_ref')).to eq('call.wav')
        expect(conversation.reload.additional_attributes.dig('recording', 'storage_key')).to eq('call.wav')
        expect(conversation.additional_attributes['keep']).to be(true)
        expect(mentioned.content_attributes.dig('data', 'transcript')).to eq('preserve me')
        expect(mentioned.content_attributes.dig('other', 'keep')).to be(true)
        expect(unrelated.reload.content_attributes.dig('data', 'recording', 'storage_key'))
          .to eq("voice-recordings/provider-two/#{account.id}/call.wav")
        expect(unrelated_conversation.reload.additional_attributes.dig('recording', 'recording_ref'))
          .to eq("voice-recordings/provider-two/#{account.id}/call.wav")
        expect(dispatcher).not_to have_received(:dispatch).with(Events::Types::MESSAGE_UPDATED, anything, anything)
      end
    end

    it 'never compresses a file outside of the storage folder' do
      outside = Rails.root.join('tmp', "outside_#{account.id}.wav")
      FileUtils.mkdir_p(outside.dirname)
      File.write(outside, 'not audio')

      session = create(
        :telephony_call_session,
        account: account,
        recording_ref: "../tmp/outside_#{account.id}.wav"
      )
      result = described_class.compress(call_session: session)

      expect(result).to include(skipped: true, reason: :file_not_found)
      expect(File.exist?(outside)).to be(true)
    ensure
      FileUtils.rm_f(outside)
    end
  end

  describe 'external commands' do
    it 'kills a command that runs longer than the timeout' do
      stub_const("#{described_class}::TIMEOUT_SECONDS", 1)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { described_class.new.send(:run_command, %w[sleep 30]) }
        .to raise_error(described_class::CompressionError, /timed out/)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
    end
  end
end
