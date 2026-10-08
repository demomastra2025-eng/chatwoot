# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::HeavyRecordingsSnapshot do
  let(:account_id) { 1_234_567 }
  let(:service) { described_class.new(account_id: account_id) }
  let(:cache_key) { "account:#{account_id}:storage_heavy_recordings_v1" }

  after { Redis::Alfred.delete(cache_key) }

  it 'keeps only the largest 200 recordings in descending size order' do
    session = Struct.new(:id, :inbox_id, :conversation_id, :created_at, :recording_ref)
    allow(Telephony::CallRecordingPlaybackUrl).to receive(:path_for).and_return('/recording')

    205.times do |index|
      service.add(session: session.new(index + 1, 1, index + 1, Time.current, 'fixture.wav'), byte_size: index + 1)
    end
    service.write!

    rows = service.snapshot[:recordings]
    expect(rows.size).to eq(200)
    expect(rows.map { |row| row[:byte_size] }).to eq(205.downto(6).to_a)
    expect(rows.first.keys).to contain_exactly(:id, :byte_size, :inbox_id, :conversation_id, :created_at, :download_url)
  end
end
