require 'rails_helper'

RSpec.describe Telephony::EventsIngestionService do
  describe '#perform' do
    let(:account) { create(:account) }
    let(:payload) do
      {
        event_key: 'evt-retry-1',
        account_id: account.id.to_s,
        call_ref: 'call-retry-1',
        event: 'answered',
        status: 'answered',
        direction: 'FROM_PSTN'
      }
    end
    let(:service) { described_class.new(payload: payload) }
    let!(:existing_call_session) do
      create(
        :telephony_call_session,
        account: account,
        external_call_ref: 'call-retry-1',
        direction: 'inbound',
        status: 'ringing',
        metadata: { 'existing' => true }
      )
    end

    it 'retries uniqueness conflicts outside the failed transaction and reuses the persisted call session' do
      expected_conversation_id = existing_call_session.conversation_id
      expected_contact_id = existing_call_session.contact_id
      expected_inbox_id = existing_call_session.inbox_id
      expected_number_binding_id = existing_call_session.number_binding_id
      save_attempts = 0

      allow(service).to receive(:save_call_session!).and_wrap_original do |original, call_session, attributes|
        save_attempts += 1
        raise ActiveRecord::RecordNotUnique if save_attempts == 1

        original.call(call_session, attributes)
      end

      result = service.perform

      expect(result).to eq(existing_call_session)
      expect(save_attempts).to eq(2)
      expect(account.telephony_events.find_by!(event_key: 'evt-retry-1')).to be_processed
      expect(existing_call_session.reload).to have_attributes(
        conversation_id: expected_conversation_id,
        contact_id: expected_contact_id,
        inbox_id: expected_inbox_id,
        number_binding_id: expected_number_binding_id,
        status: 'in-progress'
      )
      expect(existing_call_session.metadata).to include(
        'existing' => true,
        'last_payload' => payload.deep_stringify_keys
      )
    end

    it 'does not downgrade a terminal call session when a late non-terminal event arrives' do
      existing_call_session.update!(status: 'completed', ended_at: 1.minute.ago)

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-late-answered-1',
          event: 'answered',
          status: 'answered'
        )
      ).perform

      expect(result.reload.status).to eq('completed')
      expect(account.telephony_events.find_by!(event_key: 'evt-late-answered-1')).to be_processed
    end

    it 'ignores older event state when a timestamp shows the session already moved forward' do
      last_event_at = Time.zone.parse(2.minutes.ago.iso8601)
      existing_call_session.update!(status: 'in-progress', last_event_at: last_event_at)

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-stale-ringing-1',
          event: 'session_started',
          status: 'ringing',
          occurred_at: 5.minutes.ago.iso8601
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'in-progress',
        last_event_at: last_event_at
      )
      expect(account.telephony_events.find_by!(event_key: 'evt-stale-ringing-1')).to be_processed
    end
  end
end
