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

      %w[caller_interrupted tool_started tool_completed tool_failed tool_async_completed tool_async_failed ai_speaking].each do |event_name|
        result = described_class.new(
          payload: payload.merge(
            event_key: "evt-#{event_name}",
            event: event_name,
            occurred_at: Time.current.iso8601,
            payload: { tool_name: 'faq_lookup', request_id: 'tool-req-1', ok: event_name.include?('completed') }
          )
        ).perform

        expect(result.reload.status).to eq('in_progress')
        expect(result.legs.last['event_type']).to eq(event_name)
      end

      tools = existing_call_session.latest_voice_message.reload.content_attributes.dig('data', 'tools')
      expect(tools.map { |tool| tool['event'] }).to include(
        'tool_started', 'tool_completed', 'tool_failed', 'tool_async_completed', 'tool_async_failed'
      )
      expect(tools.map { |tool| tool['name'] }).to all(eq('faq_lookup'))
      expect(tools.filter_map { |tool| tool['request_id'] }).to all(eq('tool-req-1'))
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

    it 'stores OneLink runtime recording_ready metadata without changing terminal call state' do
      existing_call_session.update!(status: 'completed', ended_at: 1.minute.ago)
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
              duration_ms: 90_000
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
