require 'rails_helper'

# A unique violation that is rescued inside an open transaction aborts the whole
# PostgreSQL transaction: the next statement (the lookup of the winner in the
# rescue block) fails with PG::InFailedSqlTransaction and the event ends failed.
# Several operator legs of one physical call race for the same rows, so every
# such rescue must run its risky insert in a savepoint.
RSpec.describe Telephony::EventsIngestionService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call_ref) { 'sipuni:janus:savepoint-leg-1' }
  let!(:call_session) do
    create(
      :telephony_call_session,
      account: account, conversation: conversation, contact: conversation.contact, inbox: inbox,
      provider: 'sipuni', direction: 'inbound', status: 'ringing', external_call_ref: call_ref
    )
  end
  let(:payload) do
    {
      event_key: 'evt-savepoint-1',
      account_id: account.id.to_s,
      call_ref: call_ref,
      provider: 'sipuni',
      event: 'session_completed',
      status: 'completed',
      direction: 'inbound'
    }
  end
  let(:service) { described_class.new(payload: payload) }

  def create_duplicate_voice_message(source_id)
    other_conversation = create(:conversation, account: account, inbox: inbox)
    create(
      :message,
      account: account, inbox: inbox, conversation: other_conversation, source_id: source_id,
      message_type: 'incoming', content_type: 'voice_call', content: 'Voice Call'
    )
  end

  describe 'a voice message that a sibling leg created first' do
    let!(:winner_message) { create_duplicate_voice_message("voice_call:#{call_ref}") }

    it 'returns the winner and leaves the open transaction usable' do
      result = nil
      later_count = nil

      ActiveRecord::Base.transaction do
        result = service.send(:build_voice_message!, call_session)
        later_count = account.messages.count
      end

      expect(result).to eq(winner_message)
      expect(later_count).to eq(1)
    end

    it 'ends the whole event processed instead of failed' do
      service.perform

      expect(account.telephony_events.find_by!(event_key: 'evt-savepoint-1')).to be_processed
      expect(call_session.reload.status).to eq('completed')
    end
  end

  describe 'a call session another event persisted for the same provider call sid' do
    let!(:winner) do
      create(
        :telephony_call_session,
        account: account, inbox: inbox, number_binding: call_session.number_binding, provider: 'sipuni', direction: 'inbound',
        external_call_ref: 'sipuni:janus:savepoint-winner', provider_call_sid: 'provider-sid-1'
      )
    end
    let(:service) { described_class.new(payload: payload.merge(provider_call_sid: 'provider-sid-1')) }

    it 'switches to the winner and leaves the open transaction usable' do
      result = nil
      later_count = nil

      ActiveRecord::Base.transaction do
        result = service.send(:persist_call_session!, account, call_session) { |_session| { provider_call_sid: 'provider-sid-1' } }
        later_count = account.telephony_call_sessions.count
      end

      expect(result).to eq(winner)
      expect(later_count).to eq(2)
    end
  end

  describe 'an event another worker recorded under the same event key' do
    let!(:recorded_event) do
      account.telephony_events.create!(event_key: 'evt-savepoint-1', event_type: 'session_completed', payload: payload)
    end

    it 'returns the recorded event and leaves the open transaction usable' do
      lookups = 0
      allow(account.telephony_events).to receive(:find_by).and_wrap_original do |original, *args|
        lookups += 1
        lookups == 1 ? nil : original.call(*args)
      end
      result = nil
      later_count = nil

      ActiveRecord::Base.transaction do
        result = service.send(:find_or_create_event!, account)
        later_count = account.telephony_events.count
      end

      expect(result).to eq(recorded_event)
      expect(later_count).to eq(1)
    end
  end

  describe 'the realtime status of a terminal event' do
    let(:operator) { create(:user, account: account) }

    before do
      create(:inbox_member, inbox: inbox, user: operator)
      allow(ActionCable.server).to receive(:broadcast)
    end

    it 'is still broadcast when the side effects of the event fail afterwards' do
      allow(service).to receive(:sync_voice_message!).and_raise(ActiveRecord::StatementInvalid, 'simulated side effect failure')

      service.perform

      expect(account.telephony_events.find_by!(event_key: 'evt-savepoint-1')).to be_failed
      expect(call_session.reload.status).to eq('completed')
      expect(ActionCable.server).to have_received(:broadcast).with(
        operator.pubsub_token,
        hash_including(event: 'voice_call.status_changed', data: hash_including(callSid: call_ref, status: 'completed'))
      ).once
    end
  end
end
