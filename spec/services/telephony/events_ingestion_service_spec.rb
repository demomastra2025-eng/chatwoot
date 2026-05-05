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
        status: 'in_progress'
      )
      expect(existing_call_session.metadata).to include(
        'existing' => true,
        'last_payload' => payload.deep_stringify_keys
      )
    end

    it 'stores native answered audit fields using canonical lifecycle status' do
      occurred_at = Time.zone.parse(1.minute.ago.iso8601)

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-native-answered-1',
          event: 'answered',
          status: 'answered',
          occurred_at: occurred_at.iso8601,
          answered_by: 'agent:42'
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'in_progress',
        answered_at: occurred_at,
        answered_by: 'agent:42'
      )
      expect(result.legs).to include(
        hash_including(
          'event_key' => 'evt-native-answered-1',
          'event_type' => 'answered',
          'status' => 'in_progress',
          'answered_by' => 'agent:42'
        )
      )
    end

    it 'preserves distinct native terminal reasons instead of collapsing them to failed or no-answer' do
      answered_at = Time.zone.parse(2.minutes.ago.iso8601)
      ended_at = Time.zone.parse(30.seconds.ago.iso8601)
      existing_call_session.update!(status: 'in_progress', answered_at: answered_at, last_event_at: answered_at)

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-native-busy-1',
          event: 'dial_status',
          status: 'busy',
          occurred_at: ended_at.iso8601,
          ended_at: ended_at.iso8601,
          answered_by: 'agent:42',
          ended_by: 'callee',
          end_reason: 'callee_busy',
          duration: 90
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'busy',
        answered_at: answered_at,
        answered_by: 'agent:42',
        ended_at: ended_at,
        ended_by: 'callee',
        end_reason: 'callee_busy',
        duration_seconds: 90
      )
      expect(account.telephony_events.find_by!(event_key: 'evt-native-busy-1')).to be_processed
    end

    it 'closes operator no-answer lifecycle events as native no_answer terminal state' do
      occurred_at = Time.zone.parse(15.seconds.ago.iso8601)
      existing_call_session.update!(status: 'ringing', last_event_at: 1.minute.ago)

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-operator-no-answer-1',
          event: 'operator_no_answer',
          occurred_at: occurred_at.iso8601,
          ended_by: 'operator',
          end_reason: 'operator_timeout'
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'no_answer',
        ended_at: occurred_at,
        ended_by: 'operator',
        end_reason: 'operator_timeout'
      )
      expect(result.legs.last).to include(
        'event_key' => 'evt-operator-no-answer-1',
        'event_type' => 'operator_no_answer',
        'status' => 'no_answer'
      )
    end

    it 'keeps the backend-claimed operator when provider answered metadata is late or ambiguous' do
      claimed_binding = create(:telephony_agent_binding, :registered, account: account, user: create(:user, account: account, role: :agent))
      provider_binding = create(:telephony_agent_binding, :registered, account: account, user: create(:user, account: account, role: :agent))
      create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        content_attributes: { 'data' => { 'status' => 'ringing' } }
      )
      existing_call_session.update!(
        status: 'connecting',
        agent_binding: claimed_binding,
        metadata: {
          'metadata' => {
            'operator_pool' => true,
            'operator_pool_size' => 2,
            'operator_candidates' => [
              { 'agent_ref' => claimed_binding.agent_ref, 'user_id' => claimed_binding.user_id },
              { 'agent_ref' => provider_binding.agent_ref, 'user_id' => provider_binding.user_id }
            ],
            'operator_candidate_user_ids' => [claimed_binding.user_id, provider_binding.user_id],
            'operator_candidate_agent_refs' => [claimed_binding.agent_ref, provider_binding.agent_ref]
          },
          'operator_claim' => {
            'agent_binding_id' => claimed_binding.id,
            'user_id' => claimed_binding.user_id
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-operator-answered-claimed-1',
          event: 'operator_answered',
          occurred_at: Time.current.iso8601,
          metadata: { agent_ref: provider_binding.agent_ref, user_id: provider_binding.user_id }
        )
      ).perform

      expect(result.reload).to have_attributes(status: 'in_progress', agent_binding_id: claimed_binding.id)
      expect(result.latest_voice_message.content_attributes.dig('data', 'meta', 'operator_claim', 'user_id')).to eq(claimed_binding.user_id)
      expect(result.latest_voice_message.content_attributes.dig('data', 'meta', 'operator_candidate_agent_refs')).to contain_exactly(
        claimed_binding.agent_ref,
        provider_binding.agent_ref
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
      existing_call_session.update!(status: 'in_progress', last_event_at: last_event_at)

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-stale-ringing-1',
          event: 'session_started',
          status: 'ringing',
          occurred_at: 5.minutes.ago.iso8601
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'in_progress',
        last_event_at: last_event_at
      )
      expect(account.telephony_events.find_by!(event_key: 'evt-stale-ringing-1')).to be_processed
    end

    it 'maps AI voice lifecycle events to native call status and AI leg audit' do
      occurred_at = Time.zone.parse(30.seconds.ago.iso8601)

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-ai-answered-1',
          event: 'ai_answered',
          occurred_at: occurred_at.iso8601,
          metadata: { provider: 'gemini-live' }
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'in_progress',
        answered_at: occurred_at,
        answered_by: 'ai_agent'
      )
      expect(result.legs).to include(
        hash_including(
          'event_key' => 'evt-ai-answered-1',
          'event_type' => 'ai_answered',
          'status' => 'in_progress',
          'leg' => 'ai',
          'answered_by' => 'ai_agent'
        )
      )
    end

    it 'keeps caller interruptions and tool events non-terminal while preserving audit legs' do
      existing_call_session.update!(status: 'in_progress')

      %w[caller_interrupted tool_started tool_completed tool_failed ai_speaking].each do |event_name|
        result = described_class.new(
          payload: payload.merge(
            event_key: "evt-#{event_name}",
            event: event_name,
            occurred_at: Time.current.iso8601
          )
        ).perform

        expect(result.reload.status).to eq('in_progress')
        expect(result.legs.last['event_type']).to eq(event_name)
      end
    end

    it 'maps transfer lifecycle events without losing the AI call session' do
      existing_call_session.update!(status: 'in_progress')

      started = described_class.new(
        payload: payload.merge(
          event_key: 'evt-transfer-started-1',
          event: 'transfer_started',
          occurred_at: Time.current.iso8601
        )
      ).perform
      expect(started.reload.status).to eq('in_progress')
      expect(started.legs.last).to include('leg' => 'operator', 'status' => 'connecting')

      answered = described_class.new(
        payload: payload.merge(
          event_key: 'evt-transfer-answered-1',
          event: 'transfer_answered',
          occurred_at: Time.current.iso8601,
          answered_by: 'operator:42'
        )
      ).perform
      expect(answered.reload).to have_attributes(status: 'in_progress', answered_by: 'operator:42')

      completed = described_class.new(
        payload: payload.merge(
          event_key: 'evt-transfer-completed-1',
          event: 'transfer_completed',
          occurred_at: Time.current.iso8601,
          ended_by: 'operator:42',
          end_reason: 'operator_completed'
        )
      ).perform
      expect(completed.reload).to have_attributes(status: 'completed', ended_by: 'operator:42', end_reason: 'operator_completed')
    end

    it 'resolves bridge event ownership from number binding before unscoped call_ref lookup' do
      other_account = create(:account)
      other_session = create(:telephony_call_session, account: other_account, external_call_ref: 'shared-bridge-call-ref', status: 'ringing')
      target_voice_channel = create(:channel_voice, :fonoster, account: account, phone_number: '+1555889010')
      Telephony::NumberBinding.sync_from_voice_channel!(target_voice_channel)
      target_binding = target_voice_channel.inbox.telephony_number_binding
      target_session = create(
        :telephony_call_session,
        account: account,
        inbox: target_voice_channel.inbox,
        number_binding: target_binding,
        external_call_ref: 'shared-bridge-call-ref',
        status: 'ringing'
      )

      result = described_class.new(
        payload: {
          event_key: 'evt-shared-bridge-call-ref',
          call_ref: 'shared-bridge-call-ref',
          number_ref: target_binding.number_ref,
          event: 'answered'
        }
      ).perform

      expect(result).to eq(target_session)
      expect(account.telephony_events.find_by!(event_key: 'evt-shared-bridge-call-ref').call_session).to eq(target_session)
      expect(other_account.telephony_events.find_by(event_key: 'evt-shared-bridge-call-ref')).to be_nil
      expect(other_session.reload.status).to eq('ringing')
    end

    it 'does not resolve bridge event ownership from call_ref alone' do
      other_account = create(:account)
      create(:telephony_call_session, account: other_account, external_call_ref: 'unscoped-bridge-call-ref', status: 'ringing')

      expect do
        described_class.new(
          payload: {
            event_key: 'evt-unscoped-bridge-call-ref',
            call_ref: 'unscoped-bridge-call-ref',
            event: 'answered'
          }
        ).perform
      end.to raise_error(Telephony::Error, /Unable to resolve account/)
    end

    it 'rejects an explicit account_id paired with another account number_ref' do
      other_account = create(:account)
      other_voice_channel = create(:channel_voice, :fonoster, account: other_account, phone_number: '+1555889030')
      Telephony::NumberBinding.sync_from_voice_channel!(other_voice_channel)

      expect do
        described_class.new(
          payload: {
            event_key: 'evt-mismatched-number-ref',
            account_id: account.id,
            call_ref: 'mismatched-number-call',
            number_ref: other_voice_channel.inbox.telephony_number_binding.number_ref,
            event: 'answered'
          }
        ).perform
      end.to raise_error(Telephony::Error, /number_ref/)

      event = account.telephony_events.find_by!(event_key: 'evt-mismatched-number-ref')
      expect(event).to be_failed
      expect(account.telephony_call_sessions.find_by(external_call_ref: 'mismatched-number-call')).to be_nil
    end
  end
end
