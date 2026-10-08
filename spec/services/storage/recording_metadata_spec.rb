# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Storage::RecordingMetadata do
  include_context 'with isolated recording storage'

  let(:account) { create(:account) }
  let(:key) { "voice-recordings/fixture/#{account.id}/recording.wav" }

  def session_with(reference, metadata)
    create(:telephony_call_session, account: account, recording_ref: reference, metadata: metadata)
  end

  def sample(reference, **changes)
    { 'account_id' => account.id, 'key' => key, 'ref' => reference, 'declared_size' => nil,
      'byte_size' => 80, 'identity' => 'fixture:inode', 'checked_at' => Time.current.to_i }.merge(changes.stringify_keys)
  end

  def expect_sizes(session, expected)
    expect(described_class.primary_size(session)).to eq(expected)
    expression = described_class.primary_size_sql(account_id: account.id)
    actual = Telephony::CallSession.where(id: session.id).pick(Arel.sql(expression))
    expect(actual).to eq(expected)
  end

  it 'accepts measured relative, absolute and bare legacy references only with their matching tenant proof' do
    [key, Storage::RecordingPaths.root.join(key).to_s, 'recording.wav'].each do |reference|
      session = session_with(reference, { 'storage_metrics' => { 'primary' => sample(reference) } })

      expect_sizes(session, 80)
    end
  end

  it 'does not trust positive foreign, remote or traversal samples even when their account proof names this tenant' do
    foreign = create(:account).id
    references = ["voice-recordings/fixture/#{foreign}/recording.wav", "voice-recordings/#{foreign}/#{account.id}/recording.wav",
                  'https://provider.example/recording.wav', '/outside/recording.wav',
                  "voice-recordings/fixture/#{account.id}/../recording.wav"]
    references.each do |reference|
      session = session_with(reference, { 'storage_metrics' => { 'primary' => sample(reference) } })

      expect_sizes(session, nil)
    end
  end

  it 'requires explicit account, canonical key and exact legacy basename proof for reused measurements' do
    foreign = create(:account).id
    samples = [sample('recording.wav').except('account_id', 'key'), sample('recording.wav', account_id: foreign),
               sample('recording.wav', key: "voice-recordings/fixture/#{foreign}/recording.wav"),
               sample('recording.wav', key: "voice-recordings/fixture/#{account.id}/other.wav"),
               sample('recording.wav', key: Storage::RecordingPaths.root.join(key).to_s)]
    samples.each do |measurement|
      session = session_with('recording.wav', { 'storage_metrics' => { 'primary' => measurement } })

      expect_sizes(session, nil)
    end
  end

  it 'keeps native sizes usable with malformed legacy storage metrics or timestamps' do
    metadata_variants = ['legacy', { 'primary' => 'legacy' }, { 'primary' => sample(key, declared_size: 40, checked_at: {}) },
                         { 'primary' => sample(key, declared_size: 40, checked_at: []) },
                         { 'primary' => sample(key, declared_size: 40, checked_at: 'invalid') },
                         { 'primary' => sample(key, declared_size: 40, checked_at: '9' * 19) }]
    metadata_variants.each do |metrics|
      session = session_with(key, { 'recording' => { 'byte_size' => 40 }, 'storage_metrics' => metrics })

      expect_sizes(session, 40)
      files = Accounts::HeavyFilesService.new(account: account, params: { file_type: 'recordings', conversation_id: session.conversation_id }).perform
      expect(files.map { |row| [row[:id], row[:byte_size]] }).to eq([["call_#{session.id}", 40]])
    end
  end

  it 'rejects stale or future timestamps without losing native declared bytes' do
    [25.hours.ago.to_i, 1.hour.from_now.to_i].each do |checked_at|
      session = session_with(key, { 'recording' => { 'byte_size' => 40 },
                                    'storage_metrics' => { 'primary' => sample(key, declared_size: 40, checked_at: checked_at) } })

      expect_sizes(session, 40)
    end
  end

  it 'reuses a measured native size only while its declared size is unchanged' do
    session = session_with(key, { 'recording' => { 'byte_size' => 40 },
                                  'storage_metrics' => { 'primary' => sample(key, declared_size: 40) } })
    expect_sizes(session, 80)
    session.update!(metadata: session.metadata.deep_merge('recording' => { 'byte_size' => 50 }))

    expect_sizes(session, 50)
  end
end
