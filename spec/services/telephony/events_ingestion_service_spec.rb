require 'rails_helper'

RSpec.describe Telephony::EventsIngestionService do
  describe '#upsert_call_session!' do
    let(:account) { create(:account) }
    let(:payload) do
      {
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
        metadata: { 'existing' => true }
      )
    end
    let(:stale_call_session) do
      account.telephony_call_sessions.build(
        external_call_ref: 'call-retry-1',
        provider: 'fonoster',
        status: 'ringing',
        direction: 'inbound'
      )
    end

    it 'rebuilds attributes from the persisted record after a uniqueness retry' do
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

      result = service.send(:upsert_call_session!, stale_call_session, account)

      expect(result).to eq(existing_call_session)
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
  end
end
