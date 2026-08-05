require 'rails_helper'

RSpec.describe 'Internal Voice AI Event and Finalize API', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+15551230006') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: voice_inbox) }
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: 'provider-call-1',
      status: 'in_progress',
      direction: 'inbound'
    )
  end

  before do
    account.enable_features!('channel_voice')
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    call_session
  end

  it 'accepts contract event payloads keyed by provider_call_id' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/event',
           params: {
             event_id: 'evt-stream-started-1',
             event_seq: 2,
             event_type: 'stream_started',
             provider_call_id: 'runtime-call-legacy-1',
             call_ref: 'runtime-call-legacy-1',
             bridge_call_ref: call_session.external_call_ref,
             runtime_call_ref: 'runtime-call-legacy-1',
             account_id: account.id,
             ai_session_id: 'ai-session-1',
             media_session_ref: 'media-session-1',
             stream_ref: 'stream-1',
             occurred_at: Time.current.iso8601,
             payload: {
               stream_ref: 'stream-1',
               direction: 'BOTH',
               input_rate: 16_000,
               output_rate: 8_000,
               gemini_model: 'gemini-3.1-flash-live-preview'
             }
           },
           headers: {
             'Authorization' => 'Bearer voice-secret',
             'X-Event-Id' => 'evt-stream-started-1',
             'X-Idempotency-Key' => 'evt-stream-started-1'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('status' => 'ok', 'event_id' => 'evt-stream-started-1')
    expect(account.telephony_events.find_by!(event_key: 'evt-stream-started-1')).to be_processed
    expect(call_session.reload.legs.last).to include(
      'event_key' => 'evt-stream-started-1',
      'event_type' => 'stream_started',
      'status' => 'in_progress',
      'bridge_call_ref' => call_session.external_call_ref,
      'runtime_call_ref' => 'runtime-call-legacy-1',
      'media_session_ref' => 'media-session-1',
      'stream_ref' => 'stream-1'
    )
  end

  it 'persists stable runtime provider and pipeline observability' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/event',
           params: {
             event_id: 'evt-runtime-connected-1',
             event_seq: 1,
             event_type: 'runtime_connected',
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             runtime_engine: 'pipecat',
             runtime_session_id: 'runtime-observability-1',
             payload: {
               provider: 'openrouter',
               pipeline_version: '0.1.0'
             }
           },
           headers: {
             'Authorization' => 'Bearer voice-secret',
             'X-Event-Id' => 'evt-runtime-connected-1',
             'X-Idempotency-Key' => 'evt-runtime-connected-1'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload.metadata.fetch('ai_voice')).to include(
      'runtime_engine' => 'pipecat',
      'runtime_session_id' => 'runtime-observability-1',
      'ai_provider' => 'openrouter',
      'pipeline_version' => '0.1.0'
    )
  end

  it 'renews the runtime lease without creating a telephony event' do
    previous_event_count = account.telephony_events.count

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/heartbeat',
           params: {
             account_id: account.id,
             call_session_id: call_session.id,
             call_ref: call_session.external_call_ref,
             runtime_engine: 'pipecat',
             runtime_session_id: 'runtime-heartbeat-1'
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'status' => 'ok',
      'terminal' => false,
      'call_session_id' => call_session.id
    )
    expect(call_session.reload.metadata['runtime_lease']).to include(
      'owner' => 'pipecat',
      'runtime_session_id' => 'runtime-heartbeat-1'
    )
    expect(account.telephony_events.count).to eq(previous_event_count)
  end

  it 'hands an active AI runtime lease from Pipecat to the Node fallback idempotently' do
    call_session.update!(
      metadata: {
        'runtime_lease' => {
          'owner' => 'pipecat',
          'runtime_session_id' => 'runtime-fallback-1',
          'generation' => 'old-generation',
          'heartbeat_at' => 5.seconds.ago.iso8601(3)
        }
      }
    )
    params = {
      account_id: account.id,
      call_session_id: call_session.id,
      call_ref: call_session.external_call_ref,
      source_runtime_engine: 'pipecat',
      source_runtime_session_id: 'runtime-fallback-1',
      source_runtime_generation: 'old-generation',
      target_runtime_engine: 'onelink-ai-voice-node',
      runtime_session_id: 'runtime-fallback-1',
      reason: 'pipecat_preflight_unavailable'
    }

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      2.times do
        post '/internal/voice/ai/runtime-handoff',
             params: params,
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
        expect(response).to have_http_status(:ok)
      end
    end

    metadata = call_session.reload.metadata
    expect(metadata['runtime_lease']).to include(
      'owner' => 'onelink-ai-voice-node',
      'runtime_session_id' => 'runtime-fallback-1',
      'source_runtime_generation' => 'old-generation'
    )
    expect(metadata.dig('runtime_lease', 'generation')).not_to eq('old-generation')
    expect(metadata['runtime_handoffs'].size).to eq(1)
    expect(response.parsed_body['status']).to eq('already_handed_off')
  end

  it 'rejects an AI runtime handoff owned by another runtime session' do
    call_session.update!(
      metadata: {
        'runtime_lease' => {
          'owner' => 'pipecat',
          'runtime_session_id' => 'runtime-owner-1',
          'generation' => 'active-generation',
          'heartbeat_at' => 5.seconds.ago.iso8601(3)
        }
      }
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/runtime-handoff',
           params: {
             account_id: account.id,
             call_session_id: call_session.id,
             source_runtime_engine: 'pipecat',
             source_runtime_session_id: 'runtime-owner-2',
             source_runtime_generation: 'active-generation',
             target_runtime_engine: 'onelink-ai-voice-node',
             runtime_session_id: 'runtime-owner-2'
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:conflict)
    expect(call_session.reload.metadata['runtime_lease']).to include(
      'owner' => 'pipecat',
      'runtime_session_id' => 'runtime-owner-1',
      'generation' => 'active-generation'
    )
  end

  it 'does not allow runtime handoff into the operator plane' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/runtime-handoff',
           params: {
             account_id: account.id,
             call_session_id: call_session.id,
             source_runtime_engine: 'pipecat',
             source_runtime_session_id: 'runtime-fallback-operator',
             source_runtime_generation: 'operator-generation',
             target_runtime_engine: 'operator',
             runtime_session_id: 'runtime-fallback-operator'
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('INVALID_RUNTIME_HANDOFF')
  end

  it 'does not let the AI fallback claim an unleased call session' do
    call_session.update!(metadata: {})

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/runtime-handoff',
           params: {
             account_id: account.id,
             call_session_id: call_session.id,
             source_runtime_engine: 'pipecat',
             source_runtime_session_id: 'runtime-unleased-1',
             source_runtime_generation: 'unleased-generation',
             target_runtime_engine: 'onelink-ai-voice-node',
             runtime_session_id: 'runtime-unleased-1'
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:conflict)
    expect(call_session.reload.metadata['runtime_lease']).to be_blank
  end

  it 'rejects stale and mismatched Pipecat runtime generations' do
    request_params = {
      account_id: account.id,
      call_session_id: call_session.id,
      call_ref: call_session.external_call_ref,
      source_runtime_engine: 'pipecat',
      source_runtime_session_id: 'runtime-fenced-1',
      source_runtime_generation: 'expected-generation',
      target_runtime_engine: 'onelink-ai-voice-node',
      runtime_session_id: 'runtime-fenced-1'
    }

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      call_session.update!(metadata: {
                             'runtime_lease' => {
                               'owner' => 'pipecat',
                               'runtime_session_id' => 'runtime-fenced-1',
                               'generation' => 'another-generation',
                               'heartbeat_at' => 5.seconds.ago.iso8601(3)
                             }
                           })
      post '/internal/voice/ai/runtime-handoff', params: request_params,
                                                 headers: { 'Authorization' => 'Bearer voice-secret' }, as: :json
      expect(response).to have_http_status(:conflict)

      call_session.update!(metadata: {
                             'runtime_lease' => {
                               'owner' => 'pipecat',
                               'runtime_session_id' => 'runtime-fenced-1',
                               'generation' => 'expected-generation',
                               'heartbeat_at' => 2.minutes.ago.iso8601(3)
                             }
                           })
      post '/internal/voice/ai/runtime-handoff', params: request_params,
                                                 headers: { 'Authorization' => 'Bearer voice-secret' }, as: :json
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['error']).to eq('RUNTIME_LEASE_EXPIRED')
    end

    expect(call_session.reload.metadata.dig('runtime_lease', 'owner')).to eq('pipecat')
  end

  it 'rejects mixed call_session_id and call_ref bindings' do
    call_session.update!(metadata: {
                           'runtime_lease' => {
                             'owner' => 'pipecat',
                             'runtime_session_id' => 'runtime-call-binding-1',
                             'generation' => 'binding-generation',
                             'heartbeat_at' => 5.seconds.ago.iso8601(3)
                           }
                         })

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/runtime-handoff',
           params: {
             account_id: account.id,
             call_session_id: call_session.id,
             call_ref: 'another-call-in-the-same-account',
             source_runtime_engine: 'pipecat',
             source_runtime_session_id: 'runtime-call-binding-1',
             source_runtime_generation: 'binding-generation',
             target_runtime_engine: 'onelink-ai-voice-node',
             runtime_session_id: 'runtime-call-binding-1'
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('CALL_SESSION_REFERENCE_MISMATCH')
    expect(call_session.reload.metadata.dig('runtime_lease', 'owner')).to eq('pipecat')
  end

  it 'rejects a heartbeat that tries to replace another runtime lease owner' do
    call_session.update!(
      metadata: {
        'runtime_lease' => {
          'owner' => 'pipecat',
          'runtime_session_id' => 'runtime-owner-1',
          'heartbeat_at' => 5.seconds.ago.iso8601(3)
        }
      }
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/heartbeat',
           params: {
             account_id: account.id,
             call_session_id: call_session.id,
             runtime_engine: 'onelink-ai-voice-node',
             runtime_session_id: 'runtime-owner-2'
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:conflict)
    expect(call_session.reload.metadata['runtime_lease']).to include(
      'owner' => 'pipecat',
      'runtime_session_id' => 'runtime-owner-1'
    )
  end

  it 'requires account scope for runtime heartbeats' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/heartbeat',
           params: {
             call_session_id: call_session.id,
             runtime_engine: 'pipecat',
             runtime_session_id: 'runtime-unscoped-1'
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(call_session.reload.metadata['runtime_lease']).to be_blank
  end

  it 'persists degraded recording metadata without making it a call terminal status' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/event',
           params: {
             event_id: 'evt-recording-incomplete-1',
             event_seq: 4,
             event_type: 'recording_incomplete',
             bridge_call_ref: call_session.external_call_ref,
             runtime_call_ref: 'runtime-recording-1',
             account_id: account.id,
             media_session_ref: 'media-recording-1',
             stream_ref: 'stream-recording-1',
             occurred_at: Time.current.iso8601,
             payload: {
               recording_status: 'incomplete',
               degraded: true,
               missing_direction: 'remote',
               reason: 'recording_write_failed'
             }
           },
           headers: {
             'Authorization' => 'Bearer voice-secret',
             'X-Idempotency-Key' => 'evt-recording-incomplete-1'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload.status).to eq('in_progress')
    expect(call_session.metadata['recording']).to include(
      'recording_status' => 'incomplete',
      'degraded' => true,
      'missing_direction' => 'remote',
      'media_session_ref' => 'media-recording-1',
      'stream_ref' => 'stream-recording-1'
    )
  end

  it 'adapts transcript_delta events into the existing transcript store' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/event',
           params: {
             event_id: 'evt-transcript-delta-1',
             event_seq: 3,
             event_type: 'transcript_delta',
             provider_call_id: call_session.external_call_ref,
             account_id: account.id,
             conversation_id: conversation.id,
             occurred_at: Time.current.iso8601,
             payload: {
               speaker: 'assistant',
               text: 'Сейчас соединю вас со специалистом.',
               is_final: true,
               provider: 'gemini-live'
             }
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload.metadata.dig('ai_voice', 'transcript', 'final_items').last).to include(
      'speaker' => 'ai',
      'text' => 'Сейчас соединю вас со специалистом.'
    )
    transcript_message = conversation.messages.find_by!(source_id: "ai_voice_turn:#{call_session.external_call_ref}:0:ai")
    expect(transcript_message).to have_attributes(message_type: 'outgoing', content: 'Сейчас соединю вас со специалистом.')
  end

  it 'finalizes once and returns an idempotent response for duplicate finalize payloads' do
    payload = {
      event_id: 'evt-finalize-1',
      event_seq: 99,
      event_type: 'finalize',
      provider_call_id: call_session.external_call_ref,
      account_id: account.id,
      conversation_id: conversation.id,
      bridge_call_ref: call_session.external_call_ref,
      runtime_call_ref: 'runtime-finalize-1',
      media_session_ref: 'media-finalize-1',
      stream_ref: 'stream-finalize-1',
      status: 'transferred',
      ended_at: Time.current.iso8601,
      duration_ms: 12_500,
      reason: 'operator_answered',
      summary: 'Caller was transferred to an operator.',
      transfer_result: {
        requested: true,
        operator_agent_aor: 'sip:1001@example.test',
        result: 'answered'
      },
      final_transcript: [
        { speaker: 'caller', text: 'Нужен оператор', at: Time.current.iso8601 },
        { speaker: 'assistant', text: 'Соединяю.', at: Time.current.iso8601 }
      ]
    }

    2.times do |index|
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/finalize',
             params: payload,
             headers: {
               'Authorization' => 'Bearer voice-secret',
               'X-Idempotency-Key' => 'evt-finalize-1',
               'X-Event-Attempt' => (index + 1).to_s
             },
             as: :json
      end

      expect(response).to have_http_status(:ok)
    end

    expect(response.parsed_body).to include('already_finalized' => true)
    expect(call_session.reload).to have_attributes(
      status: 'completed',
      end_reason: 'operator_answered',
      summary: 'Caller was transferred to an operator.',
      duration_seconds: 13
    )
    expect(call_session.metadata.dig('ai_voice', 'finalize')).to include(
      'event_id' => 'evt-finalize-1',
      'status' => 'transferred',
      'stored_status' => 'completed',
      'bridge_call_ref' => call_session.external_call_ref,
      'runtime_call_ref' => 'runtime-finalize-1',
      'media_session_ref' => 'media-finalize-1',
      'stream_ref' => 'stream-finalize-1'
    )
    expect(call_session.metadata.dig('ai_voice', 'final_transcript').pluck('speaker')).to include('caller', 'assistant')
    expect(account.telephony_events.where(event_key: 'evt-finalize-1').count).to eq(1)
    expect(conversation.reload.additional_attributes['call_status']).to eq('completed')
  end

  it 'does not close a newer call when a reused conversation receives an older finalize' do
    conversation.update!(
      additional_attributes: {
        'telephony_call_ref' => 'newer-provider-call',
        'call_status' => 'in_progress'
      }
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/finalize',
           params: {
             event_id: 'evt-finalize-superseded-call-1',
             event_type: 'finalize',
             provider_call_id: call_session.external_call_ref,
             account_id: account.id,
             conversation_id: conversation.id,
             status: 'completed',
             reason: 'normal_clearing'
           },
           headers: {
             'Authorization' => 'Bearer voice-secret',
             'X-Idempotency-Key' => 'evt-finalize-superseded-call-1'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(conversation.reload.additional_attributes).to include(
      'telephony_call_ref' => 'newer-provider-call',
      'call_status' => 'in_progress'
    )
  end

  it 'keeps conversation final status aligned with the stored finalize when a conflicting duplicate arrives' do
    first_payload = {
      event_id: 'evt-finalize-conflict-original-1',
      event_type: 'finalize',
      provider_call_id: call_session.external_call_ref,
      account_id: account.id,
      conversation_id: conversation.id,
      status: 'completed',
      reason: 'normal_clearing',
      final_transcript: [
        { speaker: 'caller', text: 'Спасибо', at: Time.current.iso8601 },
        { speaker: 'assistant', text: 'До свидания.', at: Time.current.iso8601 }
      ]
    }
    conflicting_payload = first_payload.merge(
      event_id: 'evt-finalize-conflict-late-1',
      status: 'failed',
      reason: 'provider_error'
    )

    [first_payload, conflicting_payload].each do |payload|
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/finalize',
             params: payload,
             headers: {
               'Authorization' => 'Bearer voice-secret',
               'X-Idempotency-Key' => payload[:event_id]
             },
             as: :json
      end
      expect(response).to have_http_status(:ok)
    end

    expect(call_session.reload.status).to eq('completed')
    expect(response.parsed_body).to include('ok' => true, 'already_finalized' => true, 'conflict' => true)
    expect(call_session.metadata.dig('ai_voice', 'finalize')).to include('status' => 'completed')
    expect(call_session.metadata.dig('ai_voice', 'finalize_conflicts').last).to include('status' => 'failed')
    expect(conversation.reload.additional_attributes['ai_voice_final_status']).to eq('completed')
  end

  it 'runs enabled Captain post-call memory and FAQ once with the voice transcript context' do
    assistant = create(:captain_assistant, account: account, config: { 'feature_memory' => true, 'feature_faq' => true })
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)
    create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      content_type: :voice_call,
      message_type: :incoming,
      content: 'Voice Call',
      content_attributes: { data: { call_sid: call_session.external_call_ref, status: 'in_progress' } }
    )
    create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      message_type: :incoming,
      content: 'Старые данные из другого обращения'
    )
    contact_notes_service = instance_double(Captain::Llm::ContactNotesService, generate_and_update_notes: nil)
    faq_service = instance_double(Captain::Llm::ConversationFaqService, generate_and_deduplicate: [])

    allow(Captain::Llm::ContactNotesService).to receive(:new) do |received_assistant, received_conversation, conversation_content:, raise_on_error:|
      expect(received_assistant).to eq(assistant)
      expect(received_conversation).to eq(conversation)
      expect(conversation_content).to include('Caller: Запомните, что я люблю доставку утром')
      expect(conversation_content).not_to include('Старые данные из другого обращения')
      expect(raise_on_error).to be(true)
      contact_notes_service
    end
    allow(Captain::Llm::ConversationFaqService).to receive(:new) do |received_assistant, received_conversation, content:, raise_on_error:|
      expect(received_assistant).to eq(assistant)
      expect(received_conversation).to eq(conversation)
      expect(content).to include('Caller: Запомните, что я люблю доставку утром')
      expect(content).not_to include('Старые данные из другого обращения')
      expect(raise_on_error).to be(true)
      faq_service
    end

    payload = {
      event_id: 'evt-finalize-captain-features-1',
      event_type: 'finalize',
      provider_call_id: call_session.external_call_ref,
      account_id: account.id,
      conversation_id: conversation.id,
      status: 'completed',
      reason: 'user_requested_end_call',
      final_transcript: [
        { speaker: 'caller', text: 'Запомните, что я люблю доставку утром', at: Time.current.iso8601 },
        { speaker: 'assistant', text: 'Запомнила. Добавлю это в заметки.', at: Time.current.iso8601 }
      ]
    }

    voice_token = 'test'

    2.times do
      perform_enqueued_jobs(only: Telephony::AiVoice::PostCallCaptainFeaturesJob) do
        with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: voice_token) do
          post '/internal/voice/ai/finalize',
               params: payload,
               headers: {
                 'Authorization' => "Bearer #{voice_token}",
                 'X-Idempotency-Key' => 'evt-finalize-captain-features-1'
               },
               as: :json
        end
      end
      expect(response).to have_http_status(:ok)
    end

    expect(Captain::Llm::ContactNotesService).to have_received(:new).once
    expect(contact_notes_service).to have_received(:generate_and_update_notes).once
    expect(Captain::Llm::ConversationFaqService).to have_received(:new).once
    expect(faq_service).to have_received(:generate_and_deduplicate).once
    expect(call_session.reload.metadata.dig('ai_voice', 'post_call_captain_features')).to include(
      'memory' => include('completed_at' => be_present, 'assistant_id' => assistant.id),
      'faq' => include('completed_at' => be_present, 'assistant_id' => assistant.id)
    )
  end

  it 'runs enabled Captain post-call memory without FAQ when only voice memory is enabled' do
    assistant = create(:captain_assistant, account: account, config: { 'feature_memory' => true, 'feature_faq' => false })
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)
    create_voice_call_message!
    contact_notes_service = instance_double(Captain::Llm::ContactNotesService, generate_and_update_notes: nil)

    allow(Captain::Llm::ContactNotesService).to receive(:new).and_return(contact_notes_service)
    allow(Captain::Llm::ConversationFaqService).to receive(:new)

    post_finalize_twice(finalize_payload_for('evt-finalize-captain-memory-only-1'))

    expect(Captain::Llm::ContactNotesService).to have_received(:new).once
    expect(contact_notes_service).to have_received(:generate_and_update_notes).once
    expect(Captain::Llm::ConversationFaqService).not_to have_received(:new)
    expect(call_session.reload.metadata.dig('ai_voice', 'post_call_captain_features')).to include(
      'memory' => include('completed_at' => be_present, 'assistant_id' => assistant.id)
    )
    expect(call_session.metadata.dig('ai_voice', 'post_call_captain_features', 'faq')).to be_blank
  end

  it 'does not run Captain post-call features when assistant feature flags are absent' do
    assistant = create(:captain_assistant, account: account, config: {})
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)
    create_voice_call_message!

    allow(Captain::Llm::ContactNotesService).to receive(:new)
    allow(Captain::Llm::ConversationFaqService).to receive(:new)

    post_finalize_twice(finalize_payload_for('evt-finalize-captain-features-absent-memory-1'))

    expect(Captain::Llm::ContactNotesService).not_to have_received(:new)
    expect(Captain::Llm::ConversationFaqService).not_to have_received(:new)
    expect(call_session.reload.metadata.dig('ai_voice', 'post_call_captain_features')).to be_blank
  end

  it 'does not run Captain post-call features when assistant feature flags are blank' do
    assistant = create(:captain_assistant, account: account, config: { 'feature_memory' => '', 'feature_faq' => '' })
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)
    create_voice_call_message!

    allow(Captain::Llm::ContactNotesService).to receive(:new)
    allow(Captain::Llm::ConversationFaqService).to receive(:new)

    post_finalize_twice(finalize_payload_for('evt-finalize-captain-features-blank-memory-1'))

    expect(Captain::Llm::ContactNotesService).not_to have_received(:new)
    expect(Captain::Llm::ConversationFaqService).not_to have_received(:new)
    expect(call_session.reload.metadata.dig('ai_voice', 'post_call_captain_features')).to be_blank
  end

  it 'does not run Captain post-call features without voice transcript context' do
    assistant = create(:captain_assistant, account: account, config: { 'feature_memory' => true, 'feature_faq' => true })
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)
    create_voice_call_message!

    allow(Captain::Llm::ContactNotesService).to receive(:new)
    allow(Captain::Llm::ConversationFaqService).to receive(:new)

    post_finalize_twice(
      finalize_payload_for('evt-finalize-captain-features-empty-transcript-1').except(:final_transcript)
    )

    expect(Captain::Llm::ContactNotesService).not_to have_received(:new)
    expect(Captain::Llm::ConversationFaqService).not_to have_received(:new)
    expect(call_session.reload.metadata.dig('ai_voice', 'post_call_captain_features')).to be_blank
  end

  it 'retries failed Captain post-call features on a duplicate finalize without rerunning completed features', :aggregate_failures do
    assistant = create(:captain_assistant, account: account, config: { 'feature_memory' => true, 'feature_faq' => true })
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)
    create_voice_call_message!
    contact_notes_service = instance_double(Captain::Llm::ContactNotesService, generate_and_update_notes: nil)
    failed_faq_service = instance_double(Captain::Llm::ConversationFaqService)
    successful_faq_service = instance_double(Captain::Llm::ConversationFaqService)
    exception_tracker = instance_double(ChatwootExceptionTracker, capture_exception: nil)

    allow(Captain::Llm::ContactNotesService).to receive(:new).and_return(contact_notes_service)
    allow(Captain::Llm::ConversationFaqService).to receive(:new).and_return(failed_faq_service, successful_faq_service)
    allow(failed_faq_service).to receive(:generate_and_deduplicate).and_raise(StandardError, 'temporary faq failure')
    allow(successful_faq_service).to receive(:generate_and_deduplicate).and_return([])
    allow(ChatwootExceptionTracker).to receive(:new).and_return(exception_tracker)

    post_finalize_twice(finalize_payload_for('evt-finalize-captain-features-retry-1'))

    expect(Captain::Llm::ContactNotesService).to have_received(:new).once
    expect(contact_notes_service).to have_received(:generate_and_update_notes).once
    expect(Captain::Llm::ConversationFaqService).to have_received(:new).twice
    expect(failed_faq_service).to have_received(:generate_and_deduplicate).once
    expect(successful_faq_service).to have_received(:generate_and_deduplicate).once
    expect(exception_tracker).to have_received(:capture_exception).once
    expect(call_session.reload.metadata.dig('ai_voice', 'post_call_captain_features')).to include(
      'memory' => include('completed_at' => be_present, 'assistant_id' => assistant.id),
      'faq' => include('completed_at' => be_present, 'assistant_id' => assistant.id)
    )
    expect(call_session.metadata.dig('ai_voice', 'post_call_captain_features', 'faq')).not_to include(
      'failed_at', 'error_class', 'error_message'
    )
  end

  it 'retries a Captain post-call feature left with a stale started marker', :aggregate_failures do
    assistant = create(:captain_assistant, account: account, config: { 'feature_faq' => true })
    create(:captain_inbox, inbox: voice_inbox, captain_assistant: assistant)
    create_voice_call_message!
    call_session.update!(
      metadata: {
        'ai_voice' => {
          'post_call_captain_features' => {
            'faq' => {
              'assistant_id' => assistant.id,
              'call_ref' => call_session.external_call_ref,
              'started_at' => 20.minutes.ago.iso8601
            }
          }
        }
      }
    )
    faq_service = instance_double(Captain::Llm::ConversationFaqService, generate_and_deduplicate: [])

    allow(Captain::Llm::ConversationFaqService).to receive(:new).and_return(faq_service)

    post_finalize_twice(finalize_payload_for('evt-finalize-captain-features-stale-start-1'))

    expect(Captain::Llm::ConversationFaqService).to have_received(:new).once
    expect(faq_service).to have_received(:generate_and_deduplicate).once
    expect(call_session.reload.metadata.dig('ai_voice', 'post_call_captain_features', 'faq')).to include(
      'completed_at' => be_present,
      'assistant_id' => assistant.id,
      'call_ref' => call_session.external_call_ref
    )
  end

  it 'inherits enabled Captain post-call memory and FAQ from the routing-policy assistant without a Captain inbox link' do
    assistant = create(:captain_assistant, account: account, config: { 'feature_memory' => true, 'feature_faq' => true })
    voice_inbox.telephony_number_binding.routing_policy.update!(captain_assistant: assistant)
    contact_notes_service = instance_double(Captain::Llm::ContactNotesService, generate_and_update_notes: nil)
    faq_service = instance_double(Captain::Llm::ConversationFaqService, generate_and_deduplicate: [])

    allow(Captain::Llm::ContactNotesService).to receive(:new).and_return(contact_notes_service)
    allow(Captain::Llm::ConversationFaqService).to receive(:new).and_return(faq_service)

    perform_enqueued_jobs(only: Telephony::AiVoice::PostCallCaptainFeaturesJob) do
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/finalize',
             params: {
               event_id: 'evt-finalize-routing-policy-captain-features-1',
               event_type: 'finalize',
               provider_call_id: call_session.external_call_ref,
               account_id: account.id,
               conversation_id: conversation.id,
               status: 'completed',
               final_transcript: [
                 { speaker: 'caller', text: 'Запомните, что мне нужна утренняя доставка', at: Time.current.iso8601 },
                 { speaker: 'assistant', text: 'Хорошо, учту это.', at: Time.current.iso8601 }
               ]
             },
             headers: {
               'Authorization' => 'Bearer voice-secret',
               'X-Idempotency-Key' => 'evt-finalize-routing-policy-captain-features-1'
             },
             as: :json
      end
    end

    expect(response).to have_http_status(:ok)
    expect(Captain::Llm::ContactNotesService).to have_received(:new).once
    expect(contact_notes_service).to have_received(:generate_and_update_notes).once
    expect(Captain::Llm::ConversationFaqService).to have_received(:new).once
    expect(faq_service).to have_received(:generate_and_deduplicate).once
    expect(call_session.reload.metadata.dig('ai_voice', 'post_call_captain_features')).to include(
      'memory' => include('completed_at' => be_present, 'assistant_id' => assistant.id),
      'faq' => include('completed_at' => be_present, 'assistant_id' => assistant.id)
    )
  end

  it 'stores voice control events as native activity messages and attaches tool trace to the latest AI message' do
    ai_message = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      content_type: :text,
      message_type: :outgoing,
      content: 'Сейчас проверю информацию.',
      source_id: "ai_voice_turn:#{call_session.external_call_ref}:1:ai",
      content_attributes: { data: { type: 'ai_voice_transcript_turn', call_ref: call_session.external_call_ref, speaker: 'ai' } }
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             action: 'tool_started',
             metadata: {
               tool_name: 'faq_lookup',
               tool_call_id: 'tool-call-1',
               provider: 'gemini-live',
               timeout_ms: 6000
             }
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(conversation.messages.activity.where(source_id: "ai_voice_event:#{call_session.external_call_ref}:tool_started:tool-call-1")).not_to exist
    expect(ai_message.reload.additional_attributes.dig('captain_trace', 'tool_steps').last).to include(
      'tool_name' => 'faq_lookup',
      'event' => 'start',
      'status' => 'start',
      'type' => 'captain_tool_event'
    )

    perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/control',
             params: {
               call_ref: call_session.external_call_ref,
               account_id: account.id,
               action: 'tool_async_completed',
               metadata: {
                 tool_name: 'faq_lookup',
                 request_id: 'tool-call-1',
                 provider: 'gemini-live',
                 ok: true,
                 pending: true,
                 async: true
               }
             },
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
      end
    end

    expect(response).to have_http_status(:ok)
    async_source_id = "ai_voice_event:#{call_session.external_call_ref}:tool_async_completed:tool-call-1"
    expect(conversation.messages.activity.where(source_id: async_source_id)).not_to exist
    expect(call_session.reload.status).to eq('in_progress')
    expect(call_session.events.where(event_type: 'tool_async_completed')).to exist
    expect(ai_message.reload.additional_attributes.dig('captain_trace', 'tool_steps').last).to include(
      'tool_name' => 'faq_lookup',
      'event' => 'finish',
      'id' => 'faq_lookup:finish:1:tool-call-1'
    )
  end

  it 'keeps native activity source ids monotonic after control event history is trimmed' do
    metadata = call_session.metadata.deep_dup
    metadata['ai_voice'] = {
      'control_event_sequence' => 100,
      'control_events' => Array.new(100) { |index| { 'action' => 'ai_speaking', 'sequence' => index + 1 } }
    }
    call_session.update!(metadata: metadata)

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      2.times do
        post '/internal/voice/ai/control',
             params: {
               call_ref: call_session.external_call_ref,
               account_id: account.id,
               action: 'ai_speaking',
               metadata: { source: 'regression' }
             },
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
        expect(response).to have_http_status(:ok)
      end
    end

    expect(call_session.reload.metadata.dig('ai_voice', 'control_event_sequence')).to eq(102)
    source_ids = [
      "ai_voice_event:#{call_session.external_call_ref}:ai_speaking:101",
      "ai_voice_event:#{call_session.external_call_ref}:ai_speaking:102"
    ]
    expect(conversation.messages.activity.where(source_id: source_ids).count).to eq(2)
  end

  it 'marks media-not-established lifecycle as a failed terminal call without pretending media existed' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             action: 'media_stream_not_established',
             metadata: {
               reason: 'media_stream_not_established',
               source: 'call.stream',
               ai_runtime_call_ref: call_session.external_call_ref,
               conversation_id: conversation.id
             }
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload).to have_attributes(
      status: 'failed',
      end_reason: 'media_stream_not_established'
    )
    expect(call_session.metadata.dig('ai_voice', 'control_events').last).to include(
      'action' => 'media_stream_not_established',
      'metadata' => include('source' => 'call.stream')
    )
  end

  it 'reconciles linked runtime session and exact voice bubble on caller hangup after media writer started' do
    runtime_call_ref = 'runtime-caller-hangup-after-writer-1'
    runtime_session = create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: runtime_call_ref,
      status: 'in_progress',
      direction: 'inbound',
      answered_by: 'ai_agent',
      metadata: {
        'ai_voice' => {
          'last_payload' => {
            'event_type' => 'media_writer_started',
            'stream_ref' => 'stream-after-writer-1',
            'media_session_ref' => 'media-after-writer-1'
          }
        }
      }
    )
    parent_message = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      content_type: :voice_call,
      message_type: :incoming,
      content: 'Voice Call',
      source_id: "voice_call:#{call_session.external_call_ref}",
      content_attributes: { data: { call_sid: call_session.external_call_ref, status: 'in_progress' } }
    )
    runtime_message = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      content_type: :voice_call,
      message_type: :incoming,
      content: 'Voice Call',
      source_id: "voice_call:#{runtime_call_ref}",
      content_attributes: { data: { call_sid: runtime_call_ref, status: 'in_progress', ai_voice: { enabled: true, state: 'speaking' } } }
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: {
             call_ref: runtime_call_ref,
             bridgeCallRef: call_session.external_call_ref,
             runtimeCallRef: runtime_call_ref,
             account_id: account.id,
             conversation_id: conversation.id,
             action: 'caller_hangup',
             metadata: {
               reason: 'caller_hangup',
               streamRef: 'stream-after-writer-1',
               mediaSessionRef: 'media-after-writer-1'
             }
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload).to have_attributes(status: 'cancelled', end_reason: 'caller_hangup')
    expect(runtime_session.reload).to have_attributes(status: 'cancelled', end_reason: 'caller_hangup')
    expect(parent_message.reload.content_attributes.dig('data', 'status')).to eq('cancelled')
    runtime_message.reload
    expect(runtime_message.content_attributes.dig('data', 'hidden')).to be(true)
    expect(runtime_message.content_attributes.dig('data', 'duplicate_of')).to eq(parent_message.source_id)
    expect(parent_message.reload.content_attributes.dig('data', 'ai_voice', 'state')).to eq('completed')
  end

  it 'accepts incomplete media-stream finalization with partial transcript payloads' do
    payload = {
      event_id: 'evt-finalize-media-closed-1',
      event_seq: 100,
      event_type: 'finalize',
      provider_call_id: call_session.external_call_ref,
      bridge_call_ref: 'bridge-call-1',
      ai_runtime_call_ref: call_session.external_call_ref,
      provider_session_id: 'gemini-session-1',
      account_id: account.id,
      conversation_id: conversation.id,
      status: 'failed',
      reason: 'media_stream_closed',
      incomplete_transcript: true,
      final_transcript: [
        { speaker: 'ai', text: 'Хотите', final: false, at: Time.current.iso8601 }
      ],
      partial_transcript: [
        { speaker: 'ai', text: 'Хотите', final: false, at: Time.current.iso8601 }
      ]
    }

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/finalize',
           params: payload,
           headers: {
             'Authorization' => 'Bearer voice-secret',
             'X-Idempotency-Key' => 'evt-finalize-media-closed-1'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload).to have_attributes(
      status: 'failed',
      end_reason: 'media_stream_closed'
    )
    expect(call_session.metadata.dig('ai_voice', 'finalize')).to include(
      'bridge_call_ref' => 'bridge-call-1',
      'ai_runtime_call_ref' => call_session.external_call_ref,
      'provider_session_id' => 'gemini-session-1'
    )
    expect(call_session.metadata.dig('ai_voice', 'finalize', 'payload')).to include(
      'incomplete_transcript' => true,
      'partial_transcript' => include(include('text' => 'Хотите', 'final' => false))
    )
    expect(call_session.metadata.dig('ai_voice', 'final_transcript').pluck('text')).to include('Хотите')
    expect(conversation.messages.where('source_id LIKE ?', "ai_voice_turn:#{call_session.external_call_ref}:%").pluck(:content)).to include('Хотите')
  end

  it 'syncs the canonical voice bubble after AI finalization so recordings render' do
    call_session.update!(
      status: 'rejected',
      recording_ref: 'voice-recordings/1/ai-call/recording.wav',
      metadata: {
        'recording' => {
          'recording_ref' => 'voice-recordings/1/ai-call/recording.wav',
          'storage_key' => 'voice-recordings/1/ai-call/recording.wav',
          'recording_status' => 'ready',
          'duration_ms' => 12_000,
          'content_type' => 'audio/wav'
        },
        'ai_voice' => { 'state' => 'attached' }
      }
    )
    voice_message = create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      content_type: :voice_call,
      message_type: :incoming,
      content: 'Voice Call',
      source_id: "voice_call:#{call_session.external_call_ref}",
      content_attributes: {
        data: {
          call_sid: call_session.external_call_ref,
          status: 'rejected',
          ai_voice: { enabled: true, answered: false, state: 'attached' }
        }
      }
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/finalize',
           params: finalize_payload_for('evt-finalize-sync-bubble-1'),
           headers: {
             'Authorization' => 'Bearer voice-secret',
             'X-Idempotency-Key' => 'evt-finalize-sync-bubble-1'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload.status).to eq('completed')
    data = voice_message.reload.content_attributes['data']
    expect(data['status']).to eq('completed')
    expect(data['recording_ref']).to eq('voice-recordings/1/ai-call/recording.wav')
    expect(data['recording_url']).to include('/api/v1/accounts/')
    expect(data.dig('recording', 'recording_status')).to eq('ready')
    expect(data.dig('ai_voice', 'answered')).to be(true)
    expect(data.dig('ai_voice', 'state')).to eq('completed')
  end

  def create_voice_call_message!
    create(
      :message,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      content_type: :voice_call,
      message_type: :incoming,
      content: 'Voice Call',
      content_attributes: { data: { call_sid: call_session.external_call_ref, status: 'in_progress' } }
    )
  end

  def finalize_payload_for(event_id)
    {
      event_id: event_id,
      event_type: 'finalize',
      provider_call_id: call_session.external_call_ref,
      account_id: account.id,
      conversation_id: conversation.id,
      status: 'completed',
      reason: 'user_requested_end_call',
      final_transcript: [
        { speaker: 'caller', text: 'Запомните мой вопрос про гарантию', at: Time.current.iso8601 },
        { speaker: 'assistant', text: 'Да, зафиксирую после звонка.', at: Time.current.iso8601 }
      ]
    }
  end

  def post_finalize_twice(payload)
    2.times do
      perform_enqueued_jobs(only: Telephony::AiVoice::PostCallCaptainFeaturesJob) do
        with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
          post '/internal/voice/ai/finalize',
               params: payload,
               headers: {
                 'Authorization' => 'Bearer voice-secret',
                 'X-Idempotency-Key' => payload[:event_id]
               },
               as: :json
        end
      end
      expect(response).to have_http_status(:ok)
    end
  end
end
