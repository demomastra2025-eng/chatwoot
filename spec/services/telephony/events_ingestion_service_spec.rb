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

    it 'reuses the exact voice call bubble when message creation races with the WhatsApp webhook' do
      existing_message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: { 'data' => { 'status' => 'ringing', 'call_sid' => 'call-retry-1' } }
      )
      service = described_class.new(payload: payload)
      messages = existing_call_session.conversation.messages
      allow(existing_call_session.conversation).to receive(:messages).and_return(messages)
      allow(messages).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

      message = service.send(:build_voice_message!, existing_call_session)

      expect(message).to eq(existing_message)
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

    it 'projects the logical call key into voice call message data and meta' do
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'inbound',
        status: 'ringing',
        metadata: {
          'metadata' => {
            'logical_call_key' => 'fonoster-inbound:shared-key',
            'call_group_key' => 'fonoster-inbound:shared-key'
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-logical-call-key-1',
          provider: 'fonoster',
          event: 'operator_ringing',
          status: 'ringing'
        )
      ).perform

      message_data = result.voice_message_for_current_call.content_attributes['data']
      expect(message_data).to include(
        'logical_call_key' => 'fonoster-inbound:shared-key',
        'logicalCallKey' => 'fonoster-inbound:shared-key',
        'call_group_key' => 'fonoster-inbound:shared-key',
        'callGroupKey' => 'fonoster-inbound:shared-key'
      )
      expect(message_data['meta']).to include(
        'logical_call_key' => 'fonoster-inbound:shared-key',
        'call_group_key' => 'fonoster-inbound:shared-key'
      )
    end

    it 'does not create a second voice bubble for an unanswered linked Fonoster inbound branch' do
      conversation = existing_call_session.conversation
      parent_session = existing_call_session
      parent_session.update!(
        provider: 'fonoster',
        direction: 'inbound',
        external_call_ref: 'parent-operator-ref',
        status: 'completed'
      )
      parent_message = create(
        :message,
        account: account,
        conversation: conversation,
        inbox: parent_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:parent-operator-ref',
        content_attributes: {
          'data' => {
            'status' => 'completed',
            'call_sid' => 'parent-operator-ref',
            'call_direction' => 'inbound'
          }
        }
      )
      child_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: parent_session.contact,
        inbox: parent_session.inbox,
        number_binding: parent_session.number_binding,
        provider: 'fonoster',
        direction: 'inbound',
        external_call_ref: 'missed-operator-ref',
        status: 'ringing',
        metadata: {
          'metadata' => {
            'logical_call_group_ref' => 'parent-operator-ref'
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-linked-missed-1',
          provider: 'fonoster',
          call_ref: child_session.external_call_ref,
          event: 'operator_no_answer',
          status: 'no_answer',
          direction: 'FROM_PSTN'
        )
      ).perform

      expect(result.reload).to have_attributes(status: 'no_answer')
      expect(conversation.messages.voice_calls.reload).to contain_exactly(parent_message)
      expect(parent_message.reload.content_attributes.dig('data', 'status')).to eq('completed')
    end

    it 'does not create a second voice bubble for an unanswered Fonoster fan-out branch with the same logical key' do
      conversation = existing_call_session.conversation
      parent_session = existing_call_session
      parent_session.update!(
        provider: 'fonoster',
        direction: 'inbound',
        external_call_ref: 'answered-fanout-ref',
        status: 'completed',
        metadata: {
          'metadata' => {
            'logical_call_key' => 'fonoster-inbound:fanout-shared-key',
            'call_group_key' => 'fonoster-inbound:fanout-shared-key'
          }
        }
      )
      parent_message = create(
        :message,
        account: account,
        conversation: conversation,
        inbox: parent_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:answered-fanout-ref',
        content_attributes: {
          'data' => {
            'status' => 'completed',
            'call_sid' => 'answered-fanout-ref',
            'call_direction' => 'inbound',
            'logical_call_key' => 'fonoster-inbound:fanout-shared-key',
            'call_group_key' => 'fonoster-inbound:fanout-shared-key'
          }
        }
      )
      child_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: parent_session.contact,
        inbox: parent_session.inbox,
        number_binding: parent_session.number_binding,
        provider: 'fonoster',
        direction: 'inbound',
        external_call_ref: 'missed-fanout-ref',
        status: 'ringing',
        metadata: {
          'metadata' => {
            'logical_call_key' => 'fonoster-inbound:fanout-shared-key',
            'call_group_key' => 'fonoster-inbound:fanout-shared-key'
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-fanout-missed-1',
          provider: 'fonoster',
          call_ref: child_session.external_call_ref,
          event: 'operator_no_answer',
          status: 'no_answer',
          direction: 'FROM_PSTN'
        )
      ).perform

      expect(result.reload).to have_attributes(status: 'no_answer')
      expect(conversation.messages.voice_calls.reload).to contain_exactly(parent_message)
    end

    it 'collapses missed Fonoster fan-out branches with the same logical key into one voice bubble' do
      conversation = existing_call_session.conversation
      logical_key = 'fonoster-inbound:fanout-all-missed-key'
      started_at = Time.current
      first_session = existing_call_session
      first_session.update!(
        provider: 'fonoster',
        direction: 'inbound',
        external_call_ref: 'missed-fanout-505',
        status: 'missed',
        from_number: '+77066318623',
        to_number: '+77072890808',
        started_at: started_at,
        ended_at: started_at + 30.seconds,
        metadata: {
          'metadata' => {
            'logical_call_key' => logical_key,
            'call_group_key' => logical_key,
            'target_extension' => '505'
          }
        }
      )
      first_message = create(
        :message,
        account: account,
        conversation: conversation,
        inbox: first_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:missed-fanout-505',
        content_attributes: {
          'data' => {
            'provider' => 'fonoster',
            'status' => 'missed',
            'call_sid' => 'missed-fanout-505',
            'call_direction' => 'inbound',
            'from_number' => '+77066318623',
            'to_number' => '+77072890808',
            'logical_call_key' => logical_key,
            'call_group_key' => logical_key
          }
        }
      )
      second_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: first_session.contact,
        inbox: first_session.inbox,
        number_binding: first_session.number_binding,
        provider: 'fonoster',
        direction: 'inbound',
        external_call_ref: 'missed-fanout-504',
        status: 'ringing',
        from_number: '+77066318623',
        to_number: '+77072890808',
        started_at: started_at + 1.second,
        metadata: {
          'metadata' => {
            'logical_call_key' => logical_key,
            'call_group_key' => logical_key,
            'target_extension' => '504'
          }
        }
      )
      conversation.update!(
        additional_attributes: {
          'fonoster_call_ref' => first_session.external_call_ref,
          'call_status' => 'missed',
          'call_direction' => 'inbound'
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-fanout-all-missed-504',
          provider: 'fonoster',
          call_ref: second_session.external_call_ref,
          event: 'session_completed',
          status: 'missed',
          end_reason: 'voice_stream_ended_before_operator_answer',
          direction: 'FROM_PSTN'
        )
      ).perform

      expect(result.reload).to have_attributes(status: 'missed')
      expect(conversation.messages.voice_calls.reload).to contain_exactly(first_message)
      expect(conversation.reload.additional_attributes).to include(
        'fonoster_call_ref' => first_session.external_call_ref,
        'call_status' => 'missed'
      )
    end

    it 'does not create a second voice bubble for an unanswered Fonoster fan-out branch when logical keys differ at a bucket boundary' do
      conversation = existing_call_session.conversation
      parent_session = existing_call_session
      parent_session.update!(
        provider: 'fonoster',
        direction: 'inbound',
        external_call_ref: 'answered-context-ref',
        status: 'completed',
        from_number: '+77066318623',
        to_number: '+77072890808',
        started_at: Time.current
      )
      parent_message = create(
        :message,
        account: account,
        conversation: conversation,
        inbox: parent_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:answered-context-ref',
        created_at: parent_session.started_at,
        content_attributes: {
          'data' => {
            'provider' => 'fonoster',
            'status' => 'completed',
            'call_sid' => 'answered-context-ref',
            'call_direction' => 'inbound',
            'from_number' => '+77066318623',
            'to_number' => '+77072890808',
            'logical_call_key' => 'fonoster-inbound:bucket-before'
          }
        }
      )
      child_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: parent_session.contact,
        inbox: parent_session.inbox,
        number_binding: parent_session.number_binding,
        provider: 'fonoster',
        direction: 'inbound',
        external_call_ref: 'missed-context-ref',
        status: 'ringing',
        from_number: '+77066318623',
        to_number: '+77072890808',
        started_at: parent_session.started_at + 3.seconds,
        metadata: {
          'metadata' => {
            'logical_call_key' => 'fonoster-inbound:bucket-after',
            'call_group_key' => 'fonoster-inbound:bucket-after'
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-fanout-context-missed-1',
          provider: 'fonoster',
          call_ref: child_session.external_call_ref,
          event: 'operator_no_answer',
          status: 'no_answer',
          direction: 'FROM_PSTN'
        )
      ).perform

      expect(result.reload).to have_attributes(status: 'no_answer')
      expect(conversation.messages.voice_calls.reload).to contain_exactly(parent_message)
    end

    it 'does not let an unanswered Fonoster fan-out branch overwrite the answered conversation state' do
      conversation = existing_call_session.conversation
      logical_key = 'fonoster-inbound:fanout-answered-key'
      answered_session = existing_call_session
      answered_session.update!(
        provider: 'fonoster',
        direction: 'inbound',
        external_call_ref: 'answered-state-ref',
        status: 'completed',
        from_number: '+77066318623',
        to_number: '+77072890808',
        started_at: Time.current,
        answered_at: 3.seconds.from_now,
        metadata: {
          'metadata' => {
            'logical_call_key' => logical_key,
            'call_group_key' => logical_key,
            'target_extension' => '505'
          },
          'operator_claim' => {
            'user_id' => 4,
            'user_name' => 'Answered Operator'
          }
        }
      )
      child_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: answered_session.contact,
        inbox: answered_session.inbox,
        number_binding: answered_session.number_binding,
        provider: 'fonoster',
        direction: 'inbound',
        external_call_ref: 'missed-state-ref',
        status: 'no_answer',
        from_number: '+77066318623',
        to_number: '+77072890808',
        started_at: answered_session.started_at + 1.second,
        metadata: {
          'metadata' => {
            'logical_call_key' => logical_key,
            'call_group_key' => logical_key,
            'target_extension' => '504'
          }
        }
      )
      conversation.update!(
        additional_attributes: {
          'fonoster_call_ref' => answered_session.external_call_ref,
          'call_status' => 'completed',
          'call_direction' => 'inbound',
          'from_number' => '+77066318623',
          'to_number' => '+77072890808'
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-fanout-no-answer-recording-ready',
          provider: 'fonoster',
          call_ref: child_session.external_call_ref,
          event: 'recording_ready',
          recording_ref: 'voice-recordings/fonoster/1/missed-state-ref.wav',
          storage_key: 'voice-recordings/fonoster/1/missed-state-ref.wav',
          duration_seconds: 0
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'no_answer',
        recording_ref: 'voice-recordings/fonoster/1/missed-state-ref.wav'
      )
      expect(conversation.reload.additional_attributes).to include(
        'fonoster_call_ref' => answered_session.external_call_ref,
        'call_status' => 'completed'
      )
      expect(
        conversation.messages.voice_calls.where(source_id: "voice_call:#{child_session.external_call_ref}")
      ).to be_empty
    end

    it 'removes an earlier unanswered Fonoster fan-out bubble when the answered branch completes' do
      conversation = existing_call_session.conversation
      missed_message = create(
        :message,
        account: account,
        conversation: conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:missed-fanout-before-answer',
        content_attributes: {
          'data' => {
            'status' => 'missed',
            'call_sid' => 'missed-fanout-before-answer',
            'call_direction' => 'inbound',
            'logical_call_key' => 'fonoster-inbound:fanout-shared-key',
            'call_group_key' => 'fonoster-inbound:fanout-shared-key'
          }
        }
      )
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'inbound',
        status: 'in_progress',
        metadata: {
          'metadata' => {
            'logical_call_key' => 'fonoster-inbound:fanout-shared-key',
            'call_group_key' => 'fonoster-inbound:fanout-shared-key'
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-fanout-completed-1',
          provider: 'fonoster',
          event: 'session_completed',
          status: 'completed',
          direction: 'FROM_PSTN'
        )
      ).perform

      expect(result.reload).to have_attributes(status: 'completed')
      expect(conversation.messages.voice_calls.reload.pluck(:id)).not_to include(missed_message.id)
      expect(conversation.messages.voice_calls.count).to eq(1)
      expect(conversation.messages.voice_calls.first.content_attributes.dig('data', 'status')).to eq('completed')
    end

    it 'uses the answered timestamp for active Fonoster conversation state' do
      started_at = Time.zone.parse(30.seconds.ago.iso8601)
      answered_at = Time.zone.parse(10.seconds.ago.iso8601)
      existing_call_session.update!(
        provider: 'fonoster',
        status: 'ringing',
        started_at: started_at,
        last_event_at: started_at
      )
      existing_call_session.conversation.update!(
        additional_attributes: {
          'call_status' => 'ringing',
          'fonoster_call_ref' => 'call-retry-1',
          'call_started_at' => 100,
          'call_ended_at' => 120,
          'call_duration' => 20
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-active-answered-timer-1',
          provider: 'fonoster',
          event: 'operator_answered',
          status: 'answered',
          occurred_at: answered_at.iso8601,
          answered_at: answered_at.iso8601,
          answered_by: 'operator_device'
        )
      ).perform

      attrs = result.conversation.reload.additional_attributes
      aggregate_failures do
        expect(result.reload).to have_attributes(status: 'in_progress', answered_at: answered_at)
        expect(attrs['call_status']).to eq('in_progress')
        expect(attrs['call_started_at']).to eq(answered_at.to_i)
        expect(attrs).not_to have_key('call_ended_at')
        expect(attrs).not_to have_key('call_duration')
      end
    end

    it 'keeps outbound CRM direction when a Fonoster operator leg reports inbound runtime direction' do
      existing_call_session.update!(
        direction: 'outbound',
        status: 'ringing',
        metadata: {
          'metadata' => {
            'mode' => 'operator',
            'routing_mode' => 'operator',
            'direction' => 'outbound',
            'call_direction' => 'outbound'
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-outbound-operator-leg-answered-1',
          event: 'operator_answered',
          status: 'answered',
          callDirection: 'inbound',
          call_direction: 'inbound',
          routingMode: 'operator',
          routing_mode: 'operator',
          leg: 'operator'
        )
      ).perform

      expect(result.reload).to have_attributes(
        direction: 'outbound',
        status: 'in_progress'
      )
      expect(result.legs.last).to include(
        'direction' => 'outbound',
        'leg' => 'operator',
        'status' => 'in_progress'
      )
    end

    it 'exposes latest native leg metadata in the voice call message for outbound UI stages' do
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'outbound',
        status: 'ringing'
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-outbound-callee-ringing-stage-1',
          provider: 'fonoster',
          event: 'dial_status',
          status: 'ringing',
          raw_status: 'RINGING',
          leg: 'callee',
          callDirection: 'outbound',
          call_direction: 'outbound'
        )
      ).perform

      message_data = result.conversation.messages.voice_calls.last.content_attributes['data']

      expect(result.legs.last).to include(
        'event_type' => 'dial_status',
        'leg' => 'callee',
        'raw_status' => 'RINGING',
        'status' => 'ringing'
      )
      expect(message_data['meta']).to include(
        'latest_event_type' => 'dial_status',
        'latest_leg' => 'callee',
        'latest_leg_status' => 'ringing',
        'latest_raw_status' => 'RINGING'
      )
    end

    it 'keeps newer answered leg metadata when a stale customer ringing event arrives later' do
      answered_at = 30.seconds.ago
      stale_ringing_at = 45.seconds.ago
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'outbound',
        status: 'ringing',
        last_event_at: stale_ringing_at - 5.seconds
      )

      described_class.new(
        payload: payload.merge(
          event_key: 'evt-outbound-callee-answered-stage-1',
          provider: 'fonoster',
          event: 'callee_answered',
          status: 'answered',
          raw_status: 'UP',
          leg: 'callee',
          occurred_at: answered_at.iso8601,
          answered_at: answered_at.iso8601,
          callDirection: 'outbound',
          call_direction: 'outbound'
        )
      ).perform

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-outbound-stale-ringing-stage-1',
          provider: 'fonoster',
          event: 'dial_status',
          status: 'ringing',
          raw_status: 'RINGING',
          leg: 'callee',
          occurred_at: stale_ringing_at.iso8601,
          callDirection: 'outbound',
          call_direction: 'outbound'
        )
      ).perform

      message_data = result.conversation.messages.voice_calls.last.content_attributes['data']

      expect(result.reload).to have_attributes(status: 'in_progress')
      expect(result.answered_at).to eq(Time.zone.parse(answered_at.iso8601))
      expect(message_data['meta']).to include(
        'latest_event_type' => 'callee_answered',
        'latest_leg' => 'callee',
        'latest_leg_status' => 'in_progress',
        'latest_raw_status' => 'UP'
      )
    end

    it 'keeps outbound direction for OneLink initiated Fonoster calls without nested route metadata' do
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'outbound',
        status: 'ringing',
        metadata: {
          'bridge_response' => {
            'provider' => 'fonoster',
            'call_ref' => existing_call_session.external_call_ref
          },
          'fonoster_call_ref' => existing_call_session.external_call_ref
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-outbound-operator-leg-answered-no-route-meta-1',
          provider: 'fonoster',
          event: 'operator_answered',
          status: 'answered',
          callDirection: 'inbound',
          call_direction: 'inbound',
          routingMode: 'operator',
          routing_mode: 'operator',
          leg: 'operator'
        )
      ).perform

      expect(result.reload).to have_attributes(
        direction: 'outbound',
        status: 'in_progress'
      )
      expect(result.legs.last).to include(
        'direction' => 'outbound',
        'leg' => 'operator',
        'status' => 'in_progress'
      )
    end

    it 'preserves outbound customer number when operator-first events report the internal extension as to_number' do
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'outbound',
        status: 'ringing',
        from_number: '+77172705175',
        to_number: '+77066318623',
        metadata: {
          'bridge_response' => {
            'from' => '9098',
            'to' => '+77066318623',
            'providerTo' => 'sip:1001@operator.cloud.vconsult.kz'
          },
          'fonoster_call_ref' => existing_call_session.external_call_ref
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-outbound-internal-extension-does-not-replace-target-1',
          provider: 'fonoster',
          event: 'session_started',
          status: 'ringing',
          direction: 'outbound',
          ingress_number: '9098',
          to_number: '9098',
          from_number: '9098',
          metadata: {
            outbound_target_number: '+77066318623'
          }
        )
      ).perform

      expect(result.reload).to have_attributes(
        direction: 'outbound',
        from_number: '+77172705175',
        to_number: '+77066318623'
      )
      expect(result.conversation.reload.additional_attributes).to include(
        'to_number' => '+77066318623'
      )
    end

    it 'closes an outbound operator-first call as no_answer when the customer never answered' do
      started_at = Time.zone.parse(45.seconds.ago.iso8601)
      ended_at = started_at + 18.seconds
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'outbound',
        status: 'ringing',
        started_at: started_at,
        last_event_at: started_at,
        to_number: '+77066318623',
        metadata: {
          'bridge_response' => {
            'from' => '9098',
            'to' => '+77066318623'
          },
          'fonoster_call_ref' => existing_call_session.external_call_ref
        },
        legs: [
          {
            'event_key' => 'evt-outbound-trying-1',
            'event_type' => 'dial_status',
            'status' => 'ringing',
            'direction' => 'outbound'
          }
        ]
      )
      message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: {
          'data' => {
            'call_sid' => 'call-retry-1',
            'status' => 'ringing',
            'call_direction' => 'outbound'
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-outbound-operator-hangup-before-customer-answer-1',
          provider: 'fonoster',
          event: 'session_completed',
          status: 'completed',
          direction: 'outbound',
          occurred_at: ended_at.iso8601,
          ended_at: ended_at.iso8601,
          ended_by: 'operator',
          end_reason: 'operator_hangup'
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'no_answer',
        ended_at: ended_at,
        ended_by: 'operator',
        end_reason: 'operator_hangup',
        duration_seconds: 18
      )
      expect(message.reload.content_attributes.dig('data', 'status')).to eq('no_answer')
      expect(result.conversation.reload.additional_attributes).to include(
        'call_status' => 'no_answer',
        'fonoster_call_ref' => existing_call_session.external_call_ref,
        'to_number' => '+77066318623'
      )
    end

    it 'keeps an outbound call completed when a customer answer event was observed before hangup' do
      started_at = Time.zone.parse(60.seconds.ago.iso8601)
      answered_at = started_at + 8.seconds
      ended_at = answered_at + 22.seconds
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'outbound',
        status: 'ringing',
        started_at: started_at,
        last_event_at: started_at,
        to_number: '+77066318623'
      )

      described_class.new(
        payload: payload.merge(
          event_key: 'evt-outbound-customer-answer-1',
          provider: 'fonoster',
          event: 'call_status',
          status: 'answered',
          direction: 'outbound',
          occurred_at: answered_at.iso8601,
          answered_at: answered_at.iso8601,
          answered_by: 'provider'
        )
      ).perform

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-outbound-completed-after-customer-answer-1',
          provider: 'fonoster',
          event: 'session_completed',
          status: 'completed',
          direction: 'outbound',
          occurred_at: ended_at.iso8601,
          ended_at: ended_at.iso8601,
          ended_by: 'operator',
          end_reason: 'operator_hangup'
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'completed',
        answered_at: answered_at,
        ended_at: ended_at,
        duration_seconds: 22
      )
    end

    it 'attaches a new Fonoster call event to the existing open contact conversation' do
      voice_channel = create(:channel_voice, :fonoster, account: account, phone_number: '+15551230000')
      voice_inbox = voice_channel.inbox
      contact = create(:contact, account: account, phone_number: '+15550001111')
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: contact.phone_number)
      existing_conversation = create(
        :conversation,
        account: account,
        inbox: voice_inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :resolved,
        identifier: 'fonoster-previous-call',
        additional_attributes: {
          'call_direction' => 'outbound',
          'call_status' => 'completed',
          'fonoster_call_ref' => 'fonoster-previous-call',
          'call_started_at' => 100,
          'call_ended_at' => 120,
          'call_duration' => 20,
          'recording_ref' => 'old-recording.wav',
          'recording' => { 'storage_key' => 'old-recording.wav' },
          'from_number' => '+15559990000',
          'to_number' => '+15550000000'
        }
      )
      create(
        :message,
        account: account,
        conversation: existing_conversation,
        inbox: voice_inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:fonoster-previous-call',
        content_attributes: { 'data' => { 'call_sid' => 'fonoster-previous-call', 'status' => 'completed' } }
      )

      result = nil
      expect do
        result = described_class.new(
          payload: {
            event_key: 'evt-fonoster-reuse-existing-conversation-1',
            account_id: account.id,
            provider: 'fonoster',
            call_ref: 'fonoster-new-outbound-call-1',
            event: 'call_created',
            status: 'ringing',
            direction: 'outbound',
            inbox_id: voice_inbox.id,
            from_number: voice_channel.phone_number,
            to_number: contact.phone_number,
            occurred_at: Time.current.iso8601
          }
        ).perform
      end.not_to(change { account.conversations.where(inbox_id: voice_inbox.id, contact_id: contact.id).count })

      existing_conversation.reload
      new_message = existing_conversation.messages.voice_calls.find_by!(source_id: 'voice_call:fonoster-new-outbound-call-1')

      aggregate_failures do
        expect(result.reload.conversation_id).to eq(existing_conversation.id)
        expect(existing_conversation.identifier).to eq('fonoster-previous-call')
        expect(existing_conversation).to be_open
        expect(existing_conversation.additional_attributes).to include(
          'call_direction' => 'outbound',
          'fonoster_call_ref' => 'fonoster-new-outbound-call-1',
          'from_number' => voice_channel.phone_number,
          'to_number' => contact.phone_number
        )
        expect(existing_conversation.additional_attributes).not_to have_key('call_started_at')
        expect(existing_conversation.additional_attributes).not_to have_key('call_ended_at')
        expect(existing_conversation.additional_attributes).not_to have_key('call_duration')
        expect(existing_conversation.additional_attributes).not_to have_key('recording_ref')
        expect(existing_conversation.additional_attributes).not_to have_key('recording')
        expect(new_message.content_attributes.dig('data', 'call_sid')).to eq('fonoster-new-outbound-call-1')
        expect(new_message.content_attributes.dig('data', 'status')).to eq('ringing')
        expect(new_message.content_attributes.dig('data', 'provider')).to eq('fonoster')
        expect(new_message.content_attributes.dig('data', 'inbox_id')).to eq(voice_inbox.id)
      end
    end

    it 'recomputes zero completed duration for answered calls with a later ended_at' do
      answered_at = Time.zone.parse(2.minutes.ago.iso8601)
      ended_at = Time.zone.parse(30.seconds.ago.iso8601)
      expected_duration = ended_at.to_i - answered_at.to_i
      existing_call_session.update!(
        status: 'in_progress',
        started_at: answered_at - 5.seconds,
        answered_at: answered_at,
        duration_seconds: 0,
        last_event_at: answered_at
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-native-completed-duration-1',
          event: 'session_completed',
          status: 'completed',
          occurred_at: ended_at.iso8601,
          ended_at: ended_at.iso8601
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'completed',
        ended_at: ended_at,
        duration_seconds: expected_duration
      )
      expect(result.conversation.reload.additional_attributes).to include(
        'call_ended_at' => ended_at.to_i,
        'call_duration' => expected_duration
      )
    end

    it 'repairs zero duration on a stale completed retry after a later diagnostic event' do
      answered_at = Time.zone.parse(3.minutes.ago.iso8601)
      ended_at = Time.zone.parse(2.minutes.ago.iso8601)
      later_event_at = ended_at + 30.seconds
      expected_duration = ended_at.to_i - answered_at.to_i
      existing_call_session.update!(
        status: 'completed',
        started_at: answered_at - 5.seconds,
        answered_at: answered_at,
        ended_at: ended_at,
        duration_seconds: 0,
        last_event_at: later_event_at
      )
      existing_call_session.conversation.update!(
        additional_attributes: {
          'call_status' => 'completed',
          'call_started_at' => (answered_at - 5.seconds).to_i,
          'call_ended_at' => ended_at.to_i,
          'call_duration' => 0
        }
      )
      message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: { 'data' => { 'status' => 'completed', 'duration' => 0, 'call_sid' => 'call-retry-1' } }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-stale-completed-duration-repair-1',
          event: 'session_completed',
          status: 'completed',
          occurred_at: ended_at.iso8601,
          ended_at: ended_at.iso8601
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'completed',
        ended_at: ended_at,
        duration_seconds: expected_duration,
        last_event_at: later_event_at
      )
      expect(result.conversation.reload.additional_attributes).to include(
        'call_ended_at' => ended_at.to_i,
        'call_duration' => expected_duration
      )
      expect(message.reload.content_attributes.dig('data', 'duration')).to eq(expected_duration)
    end

    it 'repairs a shorter early terminal duration when the final session_completed arrives later' do
      answered_at = Time.zone.parse(45.seconds.ago.iso8601)
      early_ended_at = answered_at + 5.seconds
      final_ended_at = answered_at + 28.seconds
      expected_duration = final_ended_at.to_i - answered_at.to_i
      existing_call_session.update!(
        provider: 'fonoster',
        status: 'completed',
        started_at: answered_at - 8.seconds,
        answered_at: answered_at,
        ended_at: early_ended_at,
        ended_by: 'caller',
        end_reason: 'remote_hangup',
        duration_seconds: 5,
        last_event_at: early_ended_at
      )
      existing_call_session.conversation.update!(
        additional_attributes: {
          'call_status' => 'completed',
          'call_started_at' => answered_at.to_i,
          'call_ended_at' => early_ended_at.to_i,
          'call_duration' => 5
        }
      )
      message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: { 'data' => { 'status' => 'completed', 'duration' => 5, 'call_sid' => 'call-retry-1' } }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-late-session-completed-duration-repair-1',
          event: 'session_completed',
          status: 'completed',
          occurred_at: final_ended_at.iso8601,
          ended_by: 'caller',
          end_reason: 'caller_hangup'
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'completed',
        ended_at: final_ended_at,
        ended_by: 'caller',
        end_reason: 'caller_hangup',
        duration_seconds: expected_duration,
        last_event_at: final_ended_at
      )
      expect(result.conversation.reload.additional_attributes).to include(
        'call_ended_at' => final_ended_at.to_i,
        'call_duration' => expected_duration
      )
      expect(message.reload.content_attributes.dig('data', 'duration')).to eq(expected_duration)
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

    it 'marks inbound calls missed when caller hangs up before the operator answers' do
      occurred_at = Time.zone.parse(15.seconds.ago.iso8601)
      started_at = occurred_at - 10.seconds
      existing_call_session.update!(
        status: 'ringing',
        direction: 'inbound',
        started_at: started_at,
        answered_at: nil,
        last_event_at: 1.minute.ago
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-inbound-operator-unanswered-1',
          event: 'session_completed',
          callDirection: 'inbound',
          occurred_at: occurred_at.iso8601,
          ended_by: 'caller',
          end_reason: 'voice_stream_ended_before_operator_answer'
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'missed',
        ended_at: occurred_at,
        ended_by: 'caller',
        end_reason: 'voice_stream_ended_before_operator_answer',
        answered_at: nil,
        duration_seconds: 10
      )
      expect(result.latest_voice_message.content_attributes.dig('data', 'status')).to eq('missed')
      expect(result.latest_voice_message.content_attributes.dig('data', 'duration')).to eq(10)
      expect(result.legs.last).to include(
        'event_key' => 'evt-inbound-operator-unanswered-1',
        'event_type' => 'session_completed',
        'status' => 'missed',
        'direction' => 'inbound'
      )

      recording_result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-inbound-operator-unanswered-recording-1',
          event: 'recording_ready',
          occurred_at: (occurred_at + 3.seconds).iso8601,
          recording_ref: 'voice-recordings/fonoster/530/call-retry-1/empty.wav',
          duration: 2
        )
      ).perform

      expect(recording_result.reload).to have_attributes(
        status: 'missed',
        duration_seconds: 10
      )
      expect(recording_result.latest_voice_message.content_attributes.dig('data', 'status')).to eq('missed')
      expect(recording_result.latest_voice_message.content_attributes.dig('data', 'duration')).to eq(10)
    end

    it 'normalizes call_ended caller_hangup reasons to cancelled' do
      occurred_at = Time.zone.parse(15.seconds.ago.iso8601)
      existing_call_session.update!(status: 'in_progress', last_event_at: 1.minute.ago)

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-call-ended-caller-hangup-1',
          event: 'call_ended',
          status: 'completed',
          occurred_at: occurred_at.iso8601,
          ended_by: 'caller',
          metadata: { hangup_reason: 'caller_hangup' }
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'cancelled',
        ended_at: occurred_at,
        ended_by: 'caller',
        end_reason: 'caller_hangup'
      )
      expect(result.legs.last).to include(
        'event_key' => 'evt-call-ended-caller-hangup-1',
        'event_type' => 'call_ended',
        'status' => 'cancelled'
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
      expect(result.latest_voice_message.content_attributes.dig('data', 'accepted_by', 'name')).to eq(
        claimed_binding.user.display_name.presence || claimed_binding.user.name.presence || claimed_binding.user.email
      )
      expect(result.latest_voice_message.content_attributes.dig('data', 'meta', 'operator_candidate_agent_refs')).to contain_exactly(
        claimed_binding.agent_ref,
        provider_binding.agent_ref
      )
    end

    it 'does not downgrade a terminal call session when a late non-terminal event arrives' do
      existing_call_session.update!(status: 'completed', ended_at: 1.minute.ago)
      message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: { 'data' => { 'status' => 'completed', 'call_sid' => 'call-retry-1' } }
      )
      original_content_attributes = message.content_attributes.deep_dup

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-late-answered-1',
          event: 'answered',
          status: 'answered'
        )
      ).perform

      expect(result.reload.status).to eq('completed')
      expect(message.reload.content_attributes).to eq(original_content_attributes)
      expect(message.content_attributes.dig('data', 'status')).to eq('completed')
      expect(account.telephony_events.find_by!(event_key: 'evt-late-answered-1')).to be_processed
    end

    it 'does not rewrite a terminal remote hangup with a later operator terminal event' do
      remote_ended_at = 20.seconds.ago
      existing_call_session.update!(
        status: 'completed',
        ended_at: remote_ended_at,
        ended_by: 'caller',
        end_reason: 'remote_hangup',
        last_event_at: remote_ended_at
      )
      message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: { 'data' => { 'status' => 'completed', 'call_sid' => 'call-retry-1' } }
      )
      original_content_attributes = message.content_attributes.deep_dup

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-late-operator-terminal-1',
          event: 'session_completed',
          status: 'completed',
          ended_at: 10.seconds.ago.iso8601,
          ended_by: 'operator',
          end_reason: 'operator_hangup'
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'completed',
        ended_by: 'caller',
        end_reason: 'remote_hangup'
      )
      expect(result.ended_at.to_i).to eq(remote_ended_at.to_i)
      expect(message.reload.content_attributes).to eq(original_content_attributes)
      expect(account.telephony_events.find_by!(event_key: 'evt-late-operator-terminal-1')).to be_processed
    end

    it 'still runs voice bubble side effects for a local webphone release after the terminal state was applied' do
      ended_at = Time.zone.parse(10.seconds.ago.iso8601)
      existing_call_session.update!(
        status: 'rejected',
        ended_at: ended_at,
        ended_by: 'user:7',
        end_reason: 'operator_rejected_from_browser',
        last_event_at: ended_at
      )
      message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: { 'data' => { 'status' => 'ringing', 'call_sid' => 'call-retry-1' } }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'webphone:rejected:call-retry-1:7',
          event: 'rejected',
          status: 'rejected',
          ended_at: (ended_at + 1.second).iso8601,
          ended_by: 'user:7',
          reason: 'operator_rejected_from_browser',
          metadata: { webphone_action: 'operator_release', chatwoot_user_id: 7 }
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'rejected',
        ended_by: 'user:7',
        end_reason: 'operator_rejected_from_browser'
      )
      expect(message.reload.content_attributes.dig('data', 'status')).to eq('rejected')
      expect(account.telephony_events.find_by!(event_key: 'webphone:rejected:call-retry-1:7')).to be_processed
    end

    it 'lets an earlier remote terminal event correct an operator hangup race' do
      operator_ended_at = 10.seconds.ago
      remote_ended_at = operator_ended_at - 2.seconds
      existing_call_session.update!(
        status: 'completed',
        ended_at: operator_ended_at,
        ended_by: 'operator',
        end_reason: 'operator_hangup',
        last_event_at: operator_ended_at
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-earlier-remote-terminal-1',
          event: 'call_status',
          status: 'completed',
          ended_at: remote_ended_at.iso8601,
          ended_by: 'caller',
          end_reason: 'remote_hangup'
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'completed',
        ended_by: 'caller',
        end_reason: 'remote_hangup'
      )
      expect(result.ended_at.to_i).to eq(remote_ended_at.to_i)
      expect(account.telephony_events.find_by!(event_key: 'evt-earlier-remote-terminal-1')).to be_processed
    end

    it 'closes a linked runtime child session when the parent bridge session is terminal' do
      ended_at = Time.zone.parse(10.seconds.ago.iso8601)
      child_session = create(
        :telephony_call_session,
        account: account,
        conversation: existing_call_session.conversation,
        contact: existing_call_session.contact,
        inbox: existing_call_session.inbox,
        number_binding: existing_call_session.number_binding,
        external_call_ref: 'runtime-child-call-1',
        status: 'ringing',
        last_event_at: 1.minute.ago
      )
      child_voice_message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:runtime-child-call-1',
        content_attributes: { 'data' => { 'status' => 'ringing', 'call_sid' => 'runtime-child-call-1' } }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-parent-terminal-child-close-1',
          event: 'session_completed',
          runtime_call_ref: 'runtime-child-call-1',
          occurred_at: ended_at.iso8601,
          ended_at: ended_at.iso8601,
          ended_by: 'caller',
          end_reason: 'media_stream_closed_after_audio'
        )
      ).perform

      expect(result.reload).to have_attributes(
        status: 'completed',
        ended_at: ended_at,
        ended_by: 'caller',
        end_reason: 'media_stream_closed_after_audio'
      )
      expect(child_session.reload).to have_attributes(
        status: 'completed',
        ended_at: ended_at,
        ended_by: 'caller',
        end_reason: 'media_stream_closed_after_audio'
      )
      expect(child_session.metadata.dig('ai_voice', 'linked_parent_terminal')).to include(
        'bridge_call_ref' => 'call-retry-1',
        'runtime_call_ref' => 'runtime-child-call-1',
        'event_key' => 'evt-parent-terminal-child-close-1'
      )
      expect(child_voice_message.reload.content_attributes.dig('data', 'status')).to eq('completed')
      expect(child_voice_message.content_attributes.dig('data', 'ai_voice')).to include(
        'enabled' => true,
        'state' => 'completed'
      )
      expect(child_session.legs.last).to include(
        'event_key' => 'evt-parent-terminal-child-close-1',
        'event_type' => 'session_completed',
        'status' => 'completed',
        'leg' => 'ai'
      )
    end

    it 'resyncs a terminal linked runtime child voice message on parent terminal retry' do
      ended_at = Time.zone.parse(15.seconds.ago.iso8601)
      child_session = create(
        :telephony_call_session,
        account: account,
        conversation: existing_call_session.conversation,
        contact: existing_call_session.contact,
        inbox: existing_call_session.inbox,
        number_binding: existing_call_session.number_binding,
        external_call_ref: 'runtime-child-call-retry-1',
        status: 'completed',
        ended_at: ended_at,
        ended_by: 'caller',
        end_reason: 'media_stream_closed_after_audio',
        last_event_at: ended_at,
        metadata: { 'ai_voice' => { 'enabled' => true } }
      )
      child_voice_message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:runtime-child-call-retry-1',
        content_attributes: { 'data' => { 'status' => 'ringing', 'call_sid' => 'runtime-child-call-retry-1' } }
      )

      described_class.new(
        payload: payload.merge(
          event_key: 'evt-parent-terminal-child-retry-sync-1',
          event: 'session_completed',
          runtime_call_ref: 'runtime-child-call-retry-1',
          occurred_at: ended_at.iso8601,
          ended_at: ended_at.iso8601,
          ended_by: 'caller',
          end_reason: 'media_stream_closed_after_audio'
        )
      ).perform

      expect(child_session.reload).to have_attributes(status: 'completed', last_event_at: ended_at)
      expect(child_voice_message.reload.content_attributes.dig('data', 'status')).to eq('completed')
      expect(child_voice_message.content_attributes.dig('data', 'ai_voice')).to include('state' => 'completed')
    end

    it 'does not resurrect a linked runtime child when late runtime events arrive after parent terminal cleanup' do
      ended_at = Time.zone.parse(20.seconds.ago.iso8601)
      child_session = create(
        :telephony_call_session,
        account: account,
        conversation: existing_call_session.conversation,
        contact: existing_call_session.contact,
        inbox: existing_call_session.inbox,
        number_binding: existing_call_session.number_binding,
        external_call_ref: 'runtime-child-call-2',
        status: 'ringing',
        last_event_at: 1.minute.ago
      )

      described_class.new(
        payload: payload.merge(
          event_key: 'evt-parent-terminal-child-close-2',
          event: 'session_completed',
          runtime_call_ref: 'runtime-child-call-2',
          occurred_at: ended_at.iso8601,
          ended_at: ended_at.iso8601,
          ended_by: 'caller',
          end_reason: 'media_stream_closed_after_audio'
        )
      ).perform

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-late-runtime-child-ai-answered-1',
          call_ref: 'runtime-child-call-2',
          event: 'ai_answered',
          occurred_at: 5.seconds.ago.iso8601
        )
      ).perform

      expect(result).to eq(child_session)
      expect(child_session.reload).to have_attributes(
        status: 'completed',
        ended_at: ended_at,
        ended_by: 'caller',
        end_reason: 'media_stream_closed_after_audio'
      )
    end

    it 'treats late AI runtime events after finalize as diagnostic-only without mutating the finalized parent or bubble' do
      finalized_at = Time.zone.parse(30.seconds.ago.iso8601)
      existing_call_session.update!(
        status: 'completed',
        ended_at: finalized_at,
        ended_by: 'caller',
        end_reason: 'caller_hangup',
        duration_seconds: 18,
        recording_ref: 'voice-recordings/1/stable-parent.wav',
        metadata: {
          'ai_voice' => {
            'finalize' => {
              'event_id' => 'evt-finalize-stable-parent-1',
              'status' => 'completed',
              'reason' => 'caller_hangup',
              'recording_ref' => 'voice-recordings/1/stable-parent.wav'
            },
            'final_transcript' => [
              { 'speaker' => 'ai', 'text' => 'Стабильный финальный текст', 'at' => finalized_at.iso8601 }
            ]
          },
          'recording' => {
            'recording_ref' => 'voice-recordings/1/stable-parent.wav',
            'storage_key' => 'voice-recordings/1/stable-parent.wav'
          }
        }
      )
      message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: {
          'data' => {
            'call_sid' => 'call-retry-1',
            'status' => 'completed',
            'recording_ref' => 'voice-recordings/1/stable-parent.wav',
            'recording' => { 'storage_key' => 'voice-recordings/1/stable-parent.wav' },
            'duration' => 18,
            'ai_voice' => { 'enabled' => true, 'state' => 'completed' }
          }
        }
      )
      original_message_data = message.content_attributes.deep_dup

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-late-provider-stream-closed-after-finalize-1',
          event: 'session_failed',
          bridge_call_ref: 'call-retry-1',
          runtime_call_ref: 'runtime-late-after-finalize-1',
          occurred_at: Time.current.iso8601,
          ended_by: 'ai',
          end_reason: 'provider_stream_closed',
          duration: 310,
          recording_url: 'voice-recordings/1/late-provider.wav',
          payload: {
            reason: 'provider_stream_closed',
            recording_ref: 'voice-recordings/1/late-provider.wav'
          }
        )
      ).perform

      expect(result).to eq(existing_call_session)
      expect(account.telephony_events.find_by!(event_key: 'evt-late-provider-stream-closed-after-finalize-1')).to be_processed
      expect(existing_call_session.reload).to have_attributes(
        status: 'completed',
        ended_at: finalized_at,
        ended_by: 'caller',
        end_reason: 'caller_hangup',
        duration_seconds: 18,
        recording_ref: 'voice-recordings/1/stable-parent.wav'
      )
      expect(existing_call_session.metadata.dig('ai_voice', 'finalize', 'reason')).to eq('caller_hangup')
      expect(existing_call_session.metadata.dig('recording', 'storage_key')).to eq('voice-recordings/1/stable-parent.wav')
      expect(message.reload.content_attributes).to eq(original_message_data)
    end

    it 'does not create or activate a late runtime child when its bridge parent is already finalized' do
      finalized_at = Time.zone.parse(25.seconds.ago.iso8601)
      existing_call_session.update!(
        status: 'completed',
        ended_at: finalized_at,
        ended_by: 'caller',
        end_reason: 'caller_hangup',
        metadata: {
          'ai_voice' => {
            'finalize' => {
              'event_id' => 'evt-finalize-parent-for-late-child-1',
              'status' => 'completed',
              'reason' => 'caller_hangup'
            }
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-late-runtime-child-after-parent-finalize-1',
          call_ref: 'runtime-child-after-finalize-1',
          bridge_call_ref: 'call-retry-1',
          event: 'app_received_call',
          occurred_at: Time.current.iso8601
        )
      ).perform

      expect(result).to eq(existing_call_session)
      expect(account.telephony_call_sessions.find_by(external_call_ref: 'runtime-child-after-finalize-1')).to be_nil
      expect(existing_call_session.reload).to have_attributes(
        status: 'completed',
        ended_at: finalized_at,
        ended_by: 'caller',
        end_reason: 'caller_hangup'
      )
      expect(existing_call_session.legs).to be_blank
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

    it 'maps AI voice lifecycle events to native call status, AI leg audit and voice bubble state' do
      occurred_at = Time.zone.parse(30.seconds.ago.iso8601)
      create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        content_attributes: { 'data' => { 'status' => 'ringing' } }
      )

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
      expect(result.latest_voice_message.content_attributes.dig('data', 'ai_voice')).to include(
        'enabled' => true,
        'answered' => true,
        'state' => 'answered',
        'latest_event' => 'ai_answered'
      )
    end

    it 'keeps caller interruptions and tool events non-terminal while preserving audit legs and voice bubble tools' do
      create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        content_attributes: { 'data' => { 'status' => 'in_progress' } }
      )
      existing_call_session.update!(status: 'in_progress')

      %w[caller_interrupted tool_started tool_completed tool_failed tool_suppressed tool_async_completed tool_async_failed post_tool_model_stall
         ai_speaking].each do |event_name|
        result = described_class.new(
          payload: payload.merge(
            event_key: "evt-#{event_name}",
            event: event_name,
            occurred_at: Time.current.iso8601,
            payload: {
              tool_name: 'faq_lookup',
              request_id: 'tool-req-1',
              ok: event_name.include?('completed'),
              input: { query: 'цена' },
              output: event_name.include?('completed') ? { answer: '1000 тг' } : nil
            }.compact
          )
        ).perform

        expect(result.reload.status).to eq('in_progress')
        expect(result.legs.last['event_type']).to eq(event_name)
      end

      tools = existing_call_session.latest_voice_message.reload.content_attributes.dig('data', 'tools')
      expect(tools.map { |tool| tool['event'] }).to include(
        'tool_started', 'tool_completed', 'tool_failed', 'tool_suppressed', 'tool_async_completed', 'tool_async_failed'
      )
      expect(tools.map { |tool| tool['name'] }).to all(eq('faq_lookup'))
      expect(tools.filter_map { |tool| tool['request_id'] }).to all(eq('tool-req-1'))
      expect(tools.map { |tool| tool['call_ref'] }).to all(eq(existing_call_session.external_call_ref))
      expect(tools.map { |tool| tool['runtime_call_ref'] }).to all(eq(existing_call_session.external_call_ref))
      expect(tools.map { |tool| tool['conversation_id'] }).to all(eq(existing_call_session.conversation_id))
      expect(tools.map { |tool| tool['input'] }).to all(eq({ 'query' => 'цена' }))
      completed_tool = tools.find { |tool| tool['event'] == 'tool_completed' }
      expect(completed_tool['output']).to eq({ 'answer' => '1000 тг' })
    end

    it 'preserves false tool input and output values in voice bubble traces' do
      create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        content_attributes: { 'data' => { 'status' => 'in_progress' } }
      )
      existing_call_session.update!(status: 'in_progress')

      described_class.new(
        payload: payload.merge(
          event_key: 'evt-tool-false-output',
          event: 'tool_completed',
          occurred_at: Time.current.iso8601,
          payload: {
            tool_name: 'availability_check',
            request_id: 'tool-req-false',
            ok: true,
            input: false,
            output: false
          },
          metadata: {
            input: { query: 'fallback input' },
            output: { answer: 'fallback output' }
          }
        )
      ).perform

      tools = existing_call_session.latest_voice_message.reload.content_attributes.dig('data', 'tools')
      tool = tools.find { |item| item['request_id'] == 'tool-req-false' }
      expect(tool['input']).to be(false)
      expect(tool['output']).to be(false)
    end

    it 'stores first_audio_out_write as non-terminal AI telemetry with stream correlation' do
      existing_call_session.update!(status: 'in_progress', answered_by: 'ai_agent')
      voice_message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: { 'data' => { 'status' => 'in_progress' } }
      )
      legacy_message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        content_attributes: { 'data' => { 'status' => 'ringing' } }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-first-audio-out-write-1',
          event: 'first_audio_out_write',
          occurred_at: Time.current.iso8601,
          media_session_ref: 'media-session-telemetry',
          stream_ref: 'stream-telemetry',
          payload: {
            first_audio_out_write_at: '2026-05-17T12:00:00.000Z',
            first_audio_out_write_bytes: 320,
            first_audio_out_write_kind: 'keepalive_silence',
            first_audio_out_non_zero_ratio: 0,
            first_audio_out_rms: 0
          }
        )
      ).perform

      expect(result.reload.status).to eq('in_progress')
      expect(result.legs.last).to include(
        'event_key' => 'evt-first-audio-out-write-1',
        'event_type' => 'first_audio_out_write',
        'status' => 'in_progress',
        'leg' => 'ai',
        'media_session_ref' => 'media-session-telemetry',
        'stream_ref' => 'stream-telemetry'
      )
      expect(result.metadata.dig('last_payload', 'payload')).to include(
        'first_audio_out_write_at' => '2026-05-17T12:00:00.000Z',
        'first_audio_out_write_bytes' => 320,
        'first_audio_out_write_kind' => 'keepalive_silence',
        'first_audio_out_non_zero_ratio' => 0,
        'first_audio_out_rms' => 0
      )
      expect(voice_message.reload.content_attributes.dig('data', 'ai_voice')).to include(
        'latest_event' => 'first_audio_out_write',
        'state' => 'answered'
      )
      expect(legacy_message.reload.content_attributes.dig('data', 'ai_voice')).to be_blank
    end

    it 'stores OneLink runtime recording_ready metadata after finalize without changing terminal call state' do
      existing_call_session.update!(
        status: 'completed',
        ended_at: 1.minute.ago,
        metadata: {
          'ai_voice' => {
            'finalize' => {
              'event_id' => 'evt-finalize-before-recording-ready-1',
              'status' => 'completed',
              'reason' => 'caller_hangup'
            }
          }
        }
      )
      message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: { 'data' => { 'status' => 'completed' } }
      )
      legacy_message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        content_attributes: { 'data' => { 'status' => 'completed' } }
      )

      account.update!(captain_features: { 'audio_transcription' => true }, audio_transcriptions: false)
      account.enable_features!('captain_integration')

      result = nil

      expect do
        result = described_class.new(
          payload: payload.merge(
            event_key: 'evt-recording-ready-1',
            event: 'recording_ready',
            occurred_at: Time.current.iso8601,
            payload: {
              recording_ref: 'recordings/accounts/1/calls/call-retry-1.wav',
              storage_key: 'voice-recordings/1/call-retry-1.wav',
              byte_size: 12_345,
              content_type: 'audio/wav',
              sha256: 'abc123',
              duration_ms: 90_000,
              recorded_by: 'onelink-ai-voice',
              mode: 'ai_voice',
              layout: 'dual_channel_stereo',
              channel_layout: { left: 'caller', right: 'voice_agent' },
              inbound_bytes: 4096,
              outbound_bytes: 2048
            },
            metadata: {
              recording: {
                writer: 'onelink-ai-voice',
                storage_provider: 'local'
              }
            }
          )
        ).perform

        expect(result.reload).to have_attributes(
          status: 'completed',
          recording_ref: 'recordings/accounts/1/calls/call-retry-1.wav',
          duration_seconds: 90
        )
        expect(result.metadata.dig('recording', 'storage_key')).to eq('voice-recordings/1/call-retry-1.wav')
        expect(result.metadata.dig('recording', 'byte_size')).to eq(12_345)
        expect(result.metadata.dig('recording', 'source')).to eq('onelink_runtime')
        expect(result.metadata.dig('recording', 'layout')).to eq('dual_channel_stereo')
        expect(result.metadata.dig('recording', 'channel_layout')).to eq({ 'left' => 'caller', 'right' => 'voice_agent' })
        expect(result.metadata.dig('recording', 'inbound_bytes')).to eq(4096)
        expect(result.metadata.dig('recording', 'outbound_bytes')).to eq(2048)
        expect(result.metadata.dig('recording', 'transcription', 'status')).to eq('queued')
        expect(result.metadata.dig('metadata', 'recording', 'writer')).to eq('onelink-ai-voice')
        expect(result.conversation.additional_attributes.dig('recording', 'storage_key')).to eq('voice-recordings/1/call-retry-1.wav')
        expect(message.reload.content_attributes.dig('data', 'recording', 'storage_key')).to eq('voice-recordings/1/call-retry-1.wav')
        recording_url = message.content_attributes.dig('data', 'recording_url')
        expect(recording_url).to start_with("/api/v1/accounts/#{account.id}/telephony/calls/call-retry-1/recording?")
        expect(recording_url).to include('recording_token=')
        expect(message.content_attributes.dig('data', 'status')).to eq('completed')
      end.to have_enqueued_job(Telephony::CallRecordingTranscriptionJob).with(existing_call_session.id)

      expect(result.reload).to have_attributes(
        status: 'completed',
        recording_ref: 'recordings/accounts/1/calls/call-retry-1.wav',
        duration_seconds: 90
      )
      expect(result.metadata.dig('recording', 'storage_key')).to eq('voice-recordings/1/call-retry-1.wav')
      expect(result.metadata.dig('recording', 'byte_size')).to eq(12_345)
      expect(result.metadata.dig('recording', 'source')).to eq('onelink_runtime')
      expect(result.metadata.dig('recording', 'layout')).to eq('dual_channel_stereo')
      expect(result.metadata.dig('recording', 'channel_layout')).to eq({ 'left' => 'caller', 'right' => 'voice_agent' })
      expect(result.metadata.dig('metadata', 'recording', 'writer')).to eq('onelink-ai-voice')
      expect(result.conversation.additional_attributes.dig('recording', 'storage_key')).to eq('voice-recordings/1/call-retry-1.wav')
      expect(message.reload.content_attributes.dig('data', 'recording', 'storage_key')).to eq('voice-recordings/1/call-retry-1.wav')
      recording_url = message.content_attributes.dig('data', 'recording_url')
      expect(recording_url).to start_with("/api/v1/accounts/#{account.id}/telephony/calls/call-retry-1/recording?")
      expect(recording_url).to include('recording_token=')
      expect(message.content_attributes.dig('data', 'status')).to eq('completed')
      expect(legacy_message.reload.content_attributes.dig('data', 'recording')).to be_blank
      expect(legacy_message.content_attributes.dig('data', 'recording_ref')).to be_blank
    end

    it 'attaches an outbound recording to the existing call session when a technical ingress belongs to another channel' do
      other_account = create(:account)
      create(:telephony_number_binding, account: other_account, phone_number: '9098', ingress_number: '9098')
      voice_channel = create(:channel_voice, :fonoster, account: account, phone_number: '+77072890808')
      voice_inbox = voice_channel.inbox
      number_binding = Telephony::NumberBinding.find_by!(account: account, inbox: voice_inbox)
      answered_at = Time.zone.parse(45.seconds.ago.iso8601)
      ended_at = answered_at + 12.seconds
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'outbound',
        status: 'completed',
        inbox: voice_inbox,
        number_binding: number_binding,
        from_number: '+77072890808',
        to_number: '+77066318623',
        answered_at: answered_at,
        ended_at: ended_at,
        duration_seconds: 12
      )
      message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: voice_inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: {
          'data' => {
            'status' => 'completed',
            'call_sid' => 'call-retry-1',
            'call_direction' => 'outbound'
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-outbound-recording-technical-ingress-1',
          provider: 'fonoster',
          event: 'recording_ready',
          status: 'completed',
          direction: 'outbound',
          ingress_number: '9098',
          caller_number: '',
          occurred_at: ended_at.iso8601,
          recording_ref: 'voice-recordings/fonoster/8/call-retry-1/audio.wav',
          storage_key: 'voice-recordings/fonoster/8/call-retry-1/audio.wav',
          byte_size: 195_884,
          duration_seconds: 12
        )
      ).perform

      expect(result.reload).to have_attributes(
        inbox_id: voice_inbox.id,
        number_binding_id: number_binding.id,
        recording_ref: 'voice-recordings/fonoster/8/call-retry-1/audio.wav',
        status: 'completed'
      )
      expect(message.reload.content_attributes.dig('data', 'recording_url')).to be_present
    end

    it 'does not expose or transcribe outbound recordings when the customer never answered' do
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'outbound',
        status: 'no_answer',
        answered_at: nil,
        started_at: 30.seconds.ago,
        ended_at: 5.seconds.ago,
        duration_seconds: 25
      )
      message = create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: { 'data' => { 'status' => 'no_answer' } }
      )
      account.update!(captain_features: { 'audio_transcription' => true }, audio_transcriptions: true)
      account.enable_features!('captain_integration')

      result = nil

      expect do
        result = described_class.new(
          payload: payload.merge(
            event_key: 'evt-outbound-no-answer-recording-ready-1',
            provider: 'fonoster',
            direction: 'outbound',
            call_direction: 'outbound',
            event: 'recording_ready',
            status: 'no_answer',
            payload: {
              recording_ref: 'recordings/accounts/1/calls/call-retry-1.wav',
              storage_key: 'voice-recordings/1/no-answer-call-retry-1.wav',
              content_type: 'audio/wav',
              duration_ms: 25_000
            }
          )
        ).perform
      end.not_to have_enqueued_job(Telephony::CallRecordingTranscriptionJob)

      aggregate_failures do
        expect(result.reload.recording_ref).to eq('recordings/accounts/1/calls/call-retry-1.wav')
        expect(result.metadata.dig('recording', 'storage_key')).to eq('voice-recordings/1/no-answer-call-retry-1.wav')
        expect(message.reload.content_attributes.dig('data', 'recording')).to be_blank
        expect(message.content_attributes.dig('data', 'recording_ref')).to be_blank
        expect(message.content_attributes.dig('data', 'recording_url')).to be_blank
        expect(result.metadata.dig('recording', 'transcription')).to be_blank
      end
    end

    it 'keeps newer Fonoster conversation state when an older call recording arrives late' do
      conversation = existing_call_session.conversation
      old_started_at = Time.zone.parse(35.minutes.ago.iso8601)
      old_ended_at = old_started_at + 8.seconds
      new_started_at = Time.zone.parse(1.minute.ago.iso8601)
      existing_call_session.update!(
        provider: 'fonoster',
        direction: 'outbound',
        status: 'no_answer',
        started_at: old_started_at,
        ended_at: old_ended_at,
        duration_seconds: 8,
        last_event_at: old_ended_at
      )
      new_call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: existing_call_session.contact,
        inbox: existing_call_session.inbox,
        number_binding: existing_call_session.number_binding,
        provider: 'fonoster',
        external_call_ref: 'call-current-1',
        direction: 'outbound',
        status: 'in_progress',
        started_at: new_started_at,
        answered_at: new_started_at + 2.seconds,
        last_event_at: new_started_at + 2.seconds
      )
      conversation.update!(
        additional_attributes: {
          'telephony_provider' => 'fonoster',
          'call_direction' => 'outbound',
          'call_status' => 'in_progress',
          'fonoster_call_ref' => new_call_session.external_call_ref,
          'from_number' => new_call_session.from_number,
          'to_number' => new_call_session.to_number,
          'call_started_at' => new_call_session.answered_at.to_i,
          'meta' => { 'initiated_at' => new_started_at.to_i }
        }
      )
      old_message = create(
        :message,
        account: account,
        conversation: conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: {
          'data' => {
            'call_sid' => 'call-retry-1',
            'status' => 'no_answer',
            'duration' => 8
          }
        }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-late-old-fonoster-recording-ready-1',
          provider: 'fonoster',
          event: 'recording_ready',
          occurred_at: Time.current.iso8601,
          recording_ref: 'voice-recordings/fonoster/530/call-retry-1/late.wav',
          duration: 1800
        )
      ).perform

      attrs = conversation.reload.additional_attributes
      old_message_data = old_message.reload.content_attributes['data']
      aggregate_failures do
        expect(result.reload).to have_attributes(
          status: 'no_answer',
          ended_at: old_ended_at,
          duration_seconds: 8,
          last_event_at: old_ended_at,
          recording_ref: 'voice-recordings/fonoster/530/call-retry-1/late.wav'
        )
        expect(attrs).to include(
          'call_status' => 'in_progress',
          'fonoster_call_ref' => new_call_session.external_call_ref,
          'from_number' => new_call_session.from_number,
          'to_number' => new_call_session.to_number
        )
        expect(attrs['recording_ref']).to be_blank
        expect(attrs['recording']).to be_blank
        expect(old_message_data).to include(
          'status' => 'no_answer',
          'duration' => 8,
          'recording_ref' => 'voice-recordings/fonoster/530/call-retry-1/late.wav'
        )
      end
    end

    it 'allows a newer Fonoster call to replace an older reusable conversation state' do
      conversation = existing_call_session.conversation
      old_started_at = Time.zone.parse(10.minutes.ago.iso8601)
      new_started_at = Time.zone.parse(30.seconds.ago.iso8601)
      existing_call_session.update!(
        provider: 'fonoster',
        external_call_ref: 'call-retry-1',
        status: 'completed',
        started_at: old_started_at,
        ended_at: old_started_at + 20.seconds,
        duration_seconds: 20,
        last_event_at: old_started_at + 20.seconds
      )
      conversation.update!(
        additional_attributes: {
          'telephony_provider' => 'fonoster',
          'call_status' => 'completed',
          'fonoster_call_ref' => 'call-retry-1',
          'call_started_at' => old_started_at.to_i,
          'call_ended_at' => (old_started_at + 20.seconds).to_i,
          'call_duration' => 20,
          'meta' => { 'initiated_at' => old_started_at.to_i }
        }
      )
      newer_call_session = create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        contact: existing_call_session.contact,
        inbox: existing_call_session.inbox,
        number_binding: existing_call_session.number_binding,
        provider: 'fonoster',
        external_call_ref: 'call-newer-terminal-1',
        direction: 'outbound',
        status: 'ringing',
        started_at: new_started_at,
        last_event_at: new_started_at
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-newer-fonoster-terminal-replaces-old-state-1',
          call_ref: newer_call_session.external_call_ref,
          provider: 'fonoster',
          event: 'session_completed',
          status: 'completed',
          direction: 'outbound',
          occurred_at: (new_started_at + 12.seconds).iso8601,
          ended_at: (new_started_at + 12.seconds).iso8601,
          ended_by: 'operator',
          end_reason: 'operator_hangup'
        )
      ).perform

      attrs = conversation.reload.additional_attributes
      aggregate_failures do
        expect(result.reload).to have_attributes(status: 'no_answer', duration_seconds: 12)
        expect(attrs).to include(
          'call_status' => 'no_answer',
          'fonoster_call_ref' => newer_call_session.external_call_ref,
          'call_duration' => 12
        )
        expect(attrs['call_ended_at']).to eq((new_started_at + 12.seconds).to_i)
      end
    end

    it 'stores recording scoped errors as recording metadata without failing the live call' do
      existing_call_session.update!(status: 'in_progress', last_event_at: 1.minute.ago)
      create(
        :message,
        account: account,
        conversation: existing_call_session.conversation,
        inbox: existing_call_session.inbox,
        content_type: 'voice_call',
        source_id: 'voice_call:call-retry-1',
        content_attributes: { 'data' => { 'status' => 'in_progress' } }
      )

      result = described_class.new(
        payload: payload.merge(
          event_key: 'evt-recording-error-1',
          event: 'error',
          occurred_at: Time.current.iso8601,
          payload: {
            scope: 'recording',
            error_code: 'upload_failed',
            error_message: 'storage temporarily unavailable'
          }
        )
      ).perform

      expect(result.reload.status).to eq('in_progress')
      expect(result.metadata.dig('recording', 'error', 'code')).to eq('upload_failed')
      expect(result.metadata.dig('recording', 'error', 'scope')).to eq('recording')
      expect(result.latest_voice_message.content_attributes.dig('data', 'recording', 'error', 'code')).to eq('upload_failed')
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

    it 'resolves bridge event ownership from a unique existing call_ref when late events omit account context' do
      existing_call_session.update!(status: 'completed', ended_at: 1.minute.ago)

      result = described_class.new(
        payload: {
          event_key: 'evt-unique-call-ref-recording-ready',
          callRef: 'call-retry-1',
          event: 'recording_ready',
          recordingUrl: 'https://cloud.vconsult.kz/api/recordings/call-retry-1.wav'
        }
      ).perform

      expect(result).to eq(existing_call_session)
      expect(account.telephony_events.find_by!(event_key: 'evt-unique-call-ref-recording-ready')).to be_processed
      expect(result.reload.recording_ref).to eq('https://cloud.vconsult.kz/api/recordings/call-retry-1.wav')
      expect(result.metadata.dig('recording', 'recording_url')).to eq('https://cloud.vconsult.kz/api/recordings/call-retry-1.wav')
      expect(result.latest_voice_message.content_attributes.dig('data', 'recording_url')).to eq(
        'https://cloud.vconsult.kz/api/recordings/call-retry-1.wav'
      )
    end

    it 'does not resolve ambiguous bridge event ownership from call_ref alone' do
      other_account = create(:account)
      create(:telephony_call_session, account: other_account, external_call_ref: 'ambiguous-bridge-call-ref', status: 'ringing')
      create(:telephony_call_session, account: account, external_call_ref: 'ambiguous-bridge-call-ref', status: 'ringing')

      expect do
        described_class.new(
          payload: {
            event_key: 'evt-ambiguous-bridge-call-ref',
            call_ref: 'ambiguous-bridge-call-ref',
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
