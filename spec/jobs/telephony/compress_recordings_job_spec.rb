# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::CompressRecordingsJob do
  let(:account) { create(:account) }

  def stuck_session(name)
    create(:telephony_call_session, account: account, recording_ref: "voice-recordings/missing/#{name}.wav")
  end

  it 'runs on a queue the main Sidekiq worker consumes' do
    expect(described_class.new.queue_name).to eq('housekeeping')
  end

  it 'passes over recordings that cannot be compressed instead of selecting them again' do
    sessions = Array.new(3) { |i| stuck_session("s#{i}") }
    ids = sessions.map(&:id).sort

    expect { described_class.perform_now(account_id: account.id, batch_size: 2) }
      .to have_enqueued_job(described_class).with(account_id: account.id, batch_size: 2, after_id: ids[1])

    expect { described_class.perform_now(account_id: account.id, batch_size: 2, after_id: ids[1]) }
      .not_to have_enqueued_job(described_class)
  end

  it 'stops when every recording is behind the cursor' do
    stuck_session('only')

    expect { described_class.perform_now(account_id: account.id, batch_size: 5, after_id: 10**9) }
      .not_to have_enqueued_job(described_class)
  end

  it 'compresses a single call session on request' do
    session = create(:telephony_call_session, account: account, recording_ref: 'voice-recordings/missing/single.wav',
                                               ended_at: 1.minute.ago)
    allow(Telephony::RecordingCompressionService).to receive(:compress).and_return({ success: true })

    described_class.perform_now(call_session_id: session.id)

    expect(Telephony::RecordingCompressionService).to have_received(:compress).with(call_session: session)
  end
end
