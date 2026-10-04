# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'

RSpec.describe Telephony::PurgeRetainedRecordingsJob do
  let(:account) { create(:account) }
  let(:storage_dir) { Rails.root.join('storage/voice-recordings/purge_spec', account.id.to_s) }
  let(:original_key) { "voice-recordings/purge_spec/#{account.id}/original.wav" }
  let(:current_key) { "voice-recordings/purge_spec/#{account.id}/compressed.mp3" }

  before do
    FileUtils.mkdir_p(storage_dir)
    File.write(storage_dir.join('original.wav'), 'original audio')
    File.write(storage_dir.join('compressed.mp3'), 'compressed audio')
  end

  after do
    FileUtils.rm_rf(storage_dir)
  end

  it 'purges only the expired original and preserves call metadata and the current recording' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      transcript_ref: 'transcripts/call-1.txt',
      summary: 'Call summary',
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'byte_size' => 14, 'expires_at' => 1.hour.ago.iso8601 } },
                  'custom' => { 'keep' => true } }
    )

    expect(described_class.perform_now).to include(purged: 1, skipped: 0)

    expect(File.exist?(storage_dir.join('original.wav'))).to be(false)
    expect(File.exist?(storage_dir.join('compressed.mp3'))).to be(true)
    session.reload
    expect(session.recording_ref).to eq(current_key)
    expect(session.transcript_ref).to eq('transcripts/call-1.txt')
    expect(session.summary).to eq('Call summary')
    expect(session.metadata.dig('recording', 'retained_original')).to include('purged_at')
    expect(session.metadata['custom']).to eq('keep' => true)
  end

  it 'keeps an expired original when another call still references that path' do
    session = create(
      :telephony_call_session,
      account: account,
      recording_ref: current_key,
      metadata: { 'recording' => { 'retained_original' => { 'storage_key' => original_key, 'expires_at' => 1.hour.ago.iso8601 } } }
    )
    create(:telephony_call_session, account: account, recording_ref: original_key)

    expect(described_class.perform_now).to include(purged: 0, skipped: 1)
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

    expect(described_class.perform_now).to include(purged: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  end

  it 'keeps an expired original when a basename holder is ambiguous across provider roots' do
    other_provider_root = Rails.root.join('storage', 'voice-recordings', 'sipuni', account.id.to_s)
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

    expect(described_class.perform_now).to include(purged: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(File.exist?(other_provider_original)).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  ensure
    FileUtils.rm_rf(other_provider_root) if defined?(other_provider_root)
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
            'trash_path' => Rails.root.join('storage/trash', account.id.to_s, 'recordings', 'retained.wav').to_s
          }]
        }
      }
    )

    expect(described_class.perform_now).to include(purged: 0, skipped: 1)
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

    expect(described_class.perform_now).to include(purged: 0, skipped: 1)
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

    expect(described_class.perform_now).to include(purged: 0, skipped: 1)
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

    expect(described_class.perform_now).to include(purged: 0, skipped: 1)
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

    expect(described_class.perform_now).to include(purged: 0, skipped: 1)
    expect(File.exist?(storage_dir.join('original.wav'))).to be(true)
    expect(session.reload.metadata.dig('recording', 'retained_original', 'purged_at')).to be_nil
  end
end
