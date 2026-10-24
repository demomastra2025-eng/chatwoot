require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::RequestStore do
  # Redis is not cleared between examples: every example has ids of its own.
  let(:account_id) { SecureRandom.random_number(1_000_000_000) + 1 }
  let(:user_id) { SecureRandom.random_number(1_000_000_000) + 1 }
  let(:conversation_id) { SecureRandom.random_number(1_000_000_000) + 1 }
  let(:attributes) do
    { 'account_id' => account_id, 'user_id' => user_id, 'conversation_id' => conversation_id, 'conversation_display_id' => 1490, 'engine' => 'agent',
      'assistant_id' => 84, 'based_on_message_id' => 1_240_074 }
  end

  describe '.create!' do
    it 'writes a queued record and points the latest of the user and conversation at it' do
      record = described_class.create!(attributes)

      expect(record).to include('status' => 'queued', 'account_id' => account_id, 'budget_seconds' => Captain::ReplySuggestion.budget_seconds)
      expect(described_class.fetch_raw(record['id'])).to eq(record)
      expect(described_class.latest_id(account_id, user_id, conversation_id)).to eq(record['id'])
    end

    it 'expires with the other state of the suggestion' do
      record = described_class.create!(attributes)

      expect(Redis::Alfred.get(described_class.key(record['id']))).to be_present
    end
  end

  describe '.fetch (the view of the manager)' do
    let(:record) { described_class.create!(attributes) }

    it 'returns nothing for an unknown id' do
      expect(described_class.fetch('nope')).to be_nil
    end

    it 'shows a queued request as it is' do
      expect(described_class.fetch(record['id'])).to include('status' => 'queued')
    end

    it 'shows the last progress of an active request' do
      described_class.write_progress(record['id'], { phase: 'tool_running' })

      expect(described_class.fetch(record['id'])['progress']).to eq('phase' => 'tool_running')
    end

    it 'shows a request that waited too long in the queue as failed{queue_timeout}, without writing it back' do
      view = described_class.fetch(record['id'], now: Time.current + described_class_wait_limit)

      expect(view).to include('status' => 'failed', 'reason_code' => 'queue_timeout', 'result' => { 'reason_code' => 'queue_timeout' })
      expect(described_class.fetch_raw(record['id'])['status']).to eq('queued')
    end

    it 'shows a running request that is long past its deadline as failed{interrupted}' do
      running = described_class.mark_running!(record, started_at: Time.current, deadline_at: Time.current + 60)

      expect(described_class.fetch(running['id'], now: Time.current + 60 + 15 + 31)).to include('status' => 'failed', 'reason_code' => 'interrupted')
      expect(described_class.fetch(running['id'], now: Time.current + 61)).to include('status' => 'running')
    end

    it 'shows a request with a cancel flag as cancelled while the job has not finished' do
      described_class.request_cancel!(record['id'])

      expect(described_class.fetch(record['id'])).to include('status' => 'cancelled', 'result' => nil)
    end

    it 'does not turn a finished request into anything else' do
      finished = described_class.finish!(record, status: 'draft', result: { 'message' => 'Здравствуйте' }, duration_ms: 1200)
      described_class.request_cancel!(record['id'])

      expect(described_class.fetch(finished['id'], now: Time.current + 3600)).to include('status' => 'draft')
    end

    def described_class_wait_limit
      Captain::ReplySuggestion::MAX_QUEUE_WAIT_SECONDS + 31
    end
  end

  describe 'the transitions of the job' do
    it 'marks a request running with its timing, and finishes it with the result and the duration' do
      record = described_class.create!(attributes)
      started = Time.zone.parse('2026-10-24 09:12:03 UTC')

      running = described_class.mark_running!(record, started_at: started, deadline_at: started + 60)
      finished = described_class.finish!(
        running, status: 'failed', result: { 'reason_code' => 'timeout' }, reason_code: 'timeout', duration_ms: 60_100
      )

      expect(running).to include('status' => 'running', 'started_at' => '2026-10-24T09:12:03.000Z', 'deadline_at' => '2026-10-24T09:13:03.000Z')
      expect(finished).to include('status' => 'failed', 'reason_code' => 'timeout', 'duration_ms' => 60_100)
      expect(described_class.fetch_raw(record['id'])).to eq(finished)
    end
  end

  describe 'the flags' do
    let(:id) { SecureRandom.uuid }

    it 'keeps the cancel flag apart from the record' do
      expect(described_class.cancel_requested?(id)).to be(false)

      described_class.request_cancel!(id)

      expect(described_class.cancel_requested?(id)).to be(true)
    end

    it 'remembers that a suggestion was acted on' do
      expect(described_class.consumed?(id)).to be(false)

      described_class.consume!(id)

      expect(described_class.consumed?(id)).to be(true)
    end
  end
end
