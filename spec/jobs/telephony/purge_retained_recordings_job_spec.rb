# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'

RSpec.describe Telephony::PurgeRetainedRecordingsJob do
  include_context 'with isolated recording storage'

  let(:account) { create(:account) }
  let(:storage_dir) { Storage::RecordingPaths.root.join('voice-recordings/purge_spec', account.id.to_s) }
  let(:original_key) { "voice-recordings/purge_spec/#{account.id}/original.wav" }
  let(:current_key) { "voice-recordings/purge_spec/#{account.id}/compressed.mp3" }

  before do
    FileUtils.mkdir_p(storage_dir)
    File.write(storage_dir.join('original.wav'), 'original audio')
    File.write(storage_dir.join('compressed.mp3'), 'compressed audio')
  end

  around do |example|
    with_modified_env(TELEPHONY_PURGE_RETAINED_RECORDINGS_ENABLED: 'true') { example.run }
  end

  context 'when the flag is not set' do
    around do |example|
      with_modified_env(TELEPHONY_PURGE_RETAINED_RECORDINGS_ENABLED: nil) { example.run }
    end

    it 'touches neither the expired original nor the call' do
      session = create(
        :telephony_call_session,
        account: account,
        recording_ref: current_key,
        metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
      )

      expect(described_class.perform_now).to eq(disabled: true)
      expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
      expect(Storage::RecordingPaths.trash_root.exist?).to be(false)
      expect(session.reload.metadata.dig('recording', 'retained_original').keys).to contain_exactly('storage_key', 'expires_at')
    end
  end

  it 'moves only the expired original into the account trash and preserves call metadata and the current recording' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      transcript_ref: 'transcripts/call-1.txt',
      summary: 'Call summary',
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'byte_size' => 14, 'expires_at' => 1.hour.ago.iso8601 } },
                  'custom' => { 'keep' => true } }
    )

    expect(described_class.perform_now).to include(trashed: 1, skipped: 0)

    expect(File.exist?(storage_dir.join('original.wav'))).to be(false)
    expect(File.exist?(storage_dir.join('compressed.mp3'))).to be(true)
    session.reload
    trash = session.metadata.dig('recording', 'retained_original', 'trash')
    expect(File.read(trash['trash_path'])).to eq('original audio')
    expect(trash).to include('original_path' => storage_dir.join('original.wav').to_s, 'bytes' => 14)
    expect(Time.zone.parse(trash['expires_at'])).to be > 29.days.from_now
    expect(session.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
    expect(session.recording_ref).to eq(current_key)
    expect(session.transcript_ref).to eq('transcripts/call-1.txt')
    expect(session.summary).to eq('Call summary')
    expect(session.metadata['custom']).to eq('keep' => true)
  end

  it 'lets an administrator restore the trashed original, which is then kept' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )
    described_class.perform_now
    trash_service = Storage::TrashService.new(account: account)

    expect(trash_service.list_trash[:items]).to contain_exactly(include(id: session.id, item_type: 'original_recording', byte_size: 14))
    expect(trash_service.restore!(item_type: 'original_recording', item_id: session.id)).to include(restored_count: 1)

    expect(File.read(storage_dir.join('original.wav'))).to eq('original audio')
    retained = session.reload.metadata.dig('recording', 'retained_original')
    expect(retained).to include('storage_key' => original_key, 'restored_at' => be_present)
    expect(retained.keys).not_to include('trash', 'expires_at')
    expect(described_class.perform_now).to include(trashed: 0)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
  end

  it 'deletes the trashed original only after its 30-day trash period' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )
    described_class.perform_now
    trash_path = session.reload.metadata.dig('recording', 'retained_original', 'trash', 'trash_path')

    expect(Storage::TrashService.purge_expired_all!).to include(purged_count: 0)
    expect(File.exist?(trash_path)).to be(true)

    travel_to(31.days.from_now) do
      expect(Storage::TrashService.purge_expired_all!).to include(purged_count: 1, failed_count: 0)
    end
    expect(File.exist?(trash_path)).to be(false)
    expect(session.reload.metadata.dig('recording', 'retained_original')).to include('purged_at' => be_present, 'status' => 'purged')
    expect(session.recording_ref).to eq(current_key)
  end

  it 'keeps the expired original when the compressed recording is missing' do
    File.delete(storage_dir.join('compressed.mp3'))
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )

    expect(described_class.perform_now).to include(trashed: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'trash')).to be_nil
  end

  it 'keeps an expired original when another call still references that path' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )
    create(:telephony_call_session, account: account, recording_ref: original_key)

    expect(described_class.perform_now).to include(trashed: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  end

  it 'keeps an expired original when a live call references it by basename' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )
    create(:telephony_call_session, account: account, recording_ref: 'original.wav')

    expect(described_class.perform_now).to include(trashed: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  end

  it 'keeps an expired original when a basename holder is ambiguous across provider roots' do
    other_provider_root = Storage::RecordingPaths.root.join('voice-recordings', 'sipuni', account.id.to_s)
    FileUtils.mkdir_p(other_provider_root)
    other_provider_original = other_provider_root.join('original.wav')
    File.write(other_provider_original, 'different provider original')

    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => {
        'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601
      } } }
    )
    create(:telephony_call_session, account: account, recording_ref: 'original.wav')

    expect(described_class.perform_now).to include(trashed: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(File.exist?(other_provider_original)).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  end

  it 'keeps an expired original while another call trash manifest references its path' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )
    create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: {
        'trash' => {
          'files' => [{
            'storage_key' => original_key,
            'original_path' => storage_dir.join('original.wav').to_s,
            'trash_path' => Storage::RecordingPaths.trash_root.join(account.id.to_s, 'recordings', 'retained.wav').to_s
          }]
        }
      }
    )

    expect(described_class.perform_now).to include(trashed: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  end

  it 'keeps an expired original while conversation top-level storage key references it' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )
    create(
      :conversation,
      account: account,
      additional_attributes: { 'storage_key' => original_key, 'transcript' => 'preserve words' }
    )

    expect(described_class.perform_now).to include(trashed: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  end

  it 'keeps an original referenced by another call retention snapshot' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )
    create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 2.days.from_now.iso8601 } } }
    )

    expect(described_class.perform_now).to include(trashed: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  end

  it 'keeps an expired original while a call metadata storage key references it' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )
    create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'storage_key' => original_key } }
    )

    expect(described_class.perform_now).to include(trashed: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  end

  it 'keeps an expired original while a message still references its storage key' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )
    conversation = create(:conversation, account: account)
    create(
      :message,
      account: account,
      conversation: conversation,
      inbox: conversation.inbox,
      content_attributes: { 'data' => { 'recording' => { 'storage_key' => storage_dir.join('original.wav').to_s } } }
    )

    expect(described_class.perform_now).to include(trashed: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  end
end
