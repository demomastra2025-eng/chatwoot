# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Storage::VoiceRecordingRemoteStorage do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:recordings_dir) { Storage::RecordingPaths.root.join('voice-recordings', 'telephony', account.id.to_s).to_s }

  before do
    allow(Rails.configuration.active_storage).to receive(:service).and_return(:s3_compatible)
  end

  after do
    FileUtils.rm_rf(recordings_dir)
  end

  it 'offloads local mp3 to ActiveStorage service and unlinks local disk duplicate' do
    FileUtils.mkdir_p(recordings_dir)
    local_mp3 = File.join(recordings_dir, 'test-call-001.mp3')
    File.binwrite(local_mp3, 'ID3-fake-mp3-audio-payload-' * 40)

    storage_key = "voice-recordings/telephony/#{account.id}/test-call-001.mp3"
    expect(described_class.offload_file!(storage_key, local_mp3, content_type: 'audio/mpeg')).to be(true)
    expect(File.exist?(local_mp3)).to be(false)
    expect(described_class.exist?(storage_key)).to be(true)

    described_class.delete_key(storage_key)
  end

  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it 'counts S3-only recordings in RecordingInventory quota and supports TrashService even with legacy basename message refs' do
    storage_key = "voice-recordings/telephony/#{account.id}/s3-only-call.mp3"
    audio_bytes = 'MP3DATA' * 500
    FileUtils.mkdir_p(recordings_dir)
    temp_local = File.join(recordings_dir, 's3-only-call.mp3')
    File.binwrite(temp_local, audio_bytes)
    described_class.offload_file!(storage_key, temp_local, content_type: 'audio/mpeg')
    expect(File.exist?(temp_local)).to be(false)

    session = Telephony::CallSession.create!(
      account: account,
      conversation: conversation,
      provider: 'sipuni',
      external_call_ref: "ext-#{SecureRandom.hex(6)}",
      direction: 'inbound',
      status: 'completed',
      from_number: '+77015554433',
      to_number: '+77273332211',
      recording_ref: storage_key,
      created_at: 7.months.ago,
      metadata: {
        'recording' => {
          'storage_provider' => 's3',
          'storage_key' => storage_key,
          'remote_stored_at' => Time.current.utc.iso8601,
          'byte_size' => audio_bytes.bytesize,
          'format' => 'mp3',
          'content_type' => 'audio/mpeg'
        }
      }
    )
    voice_msg = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      content: 'Звонок',
      content_attributes: { 'data' => { 'recording_ref' => 's3-only-call.mp3' } }
    )

    inv_summary = Storage::RecordingInventory.new(account: account).calculate
    expect(inv_summary[:active]).to eq(audio_bytes.bytesize)

    trash_svc = Storage::TrashService.new(account: account)
    preview = trash_svc.preview(file_type: 'recordings', older_than_months: 6)
    moved = trash_svc.move_to_trash!(
      file_type: 'recordings', older_than_months: 6, preview_token: preview[:confirmation_token], confirmed: true
    )
    expect(moved[:moved_count]).to eq(1)
    expect(session.reload.recording_ref).to be_nil
    expect(voice_msg.reload.content_attributes.dig('data', 'recording_ref')).to be_nil
    expect(described_class.exist?(storage_key)).to be(true)

    trash_summary = Storage::RecordingInventory.new(account: account).calculate
    expect(trash_summary[:active]).to eq(0)
    expect(trash_summary[:trash]).to eq(audio_bytes.bytesize)

    restored = trash_svc.restore!(restore_all: true)
    expect(restored[:restored_count]).to eq(1)
    expect(session.reload.recording_ref).to eq(storage_key)
    expect(voice_msg.reload.content_attributes.dig('data', 'recording_ref')).to eq(storage_key)

    preview2 = trash_svc.preview(file_type: 'recordings', older_than_months: 6)
    trash_svc.move_to_trash!(
      file_type: 'recordings', older_than_months: 6, preview_token: preview2[:confirmation_token], confirmed: true
    )
    purged = trash_svc.empty_trash!(purge_all: true)
    expect(purged[:purged_count]).to eq(1)
    expect(described_class.exist?(storage_key)).to be(false)
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations

  # rubocop:disable RSpec/MultipleExpectations
  it 'drains existing local mp3 duplicates with legacy basename recording_ref to S3 via OffloadLocalRecordingsService' do
    FileUtils.mkdir_p(recordings_dir)
    local_mp3 = File.join(recordings_dir, 'legacy-local.mp3')
    bytes = 'LEGACY-MP3-BYTES-' * 100
    File.binwrite(local_mp3, bytes)
    expected_key = "voice-recordings/telephony/#{account.id}/legacy-local.mp3"

    session = Telephony::CallSession.create!(
      account: account,
      provider: 'sipuni',
      external_call_ref: "legacy-#{SecureRandom.hex(6)}",
      direction: 'inbound',
      status: 'completed',
      from_number: '+77019998877',
      to_number: '+77271112233',
      recording_ref: 'legacy-local.mp3',
      metadata: { 'recording' => { 'format' => 'mp3', 'storage_key' => 'legacy-local.mp3' } }
    )

    result = Storage::OffloadLocalRecordingsService.new(account: account).perform
    expect(result[:offloaded]).to eq(1)
    expect(File.exist?(local_mp3)).to be(false)

    rec = session.reload.metadata['recording']
    expect(session.recording_ref).to eq(expected_key)
    expect(rec['storage_key']).to eq(expected_key)
    expect(rec['storage_provider']).to eq('s3')
    expect(rec['byte_size']).to eq(bytes.bytesize)
    expect(Storage::RecordingInventory.new(account: account).calculate[:active]).to eq(bytes.bytesize)
    expect(described_class.exist?(expected_key)).to be(true)

    described_class.delete_key(expected_key)
  end
  # rubocop:enable RSpec/MultipleExpectations
end
