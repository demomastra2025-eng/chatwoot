require 'rails_helper'

RSpec.describe 'Internal Voice AI Event and Finalize API', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: '+15551230006') }
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
             provider_call_id: call_session.external_call_ref,
             account_id: account.id,
             ai_session_id: 'ai-session-1',
             media_session_ref: 'media-session-1',
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
      'status' => 'in_progress'
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
      'stored_status' => 'completed'
    )
    expect(call_session.metadata.dig('ai_voice', 'final_transcript').pluck('speaker')).to include('caller', 'assistant')
    expect(account.telephony_events.where(event_key: 'evt-finalize-1').count).to eq(1)
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
    contact_notes_service = instance_double(Captain::Llm::ContactNotesService, generate_and_update_notes: nil)
    faq_service = instance_double(Captain::Llm::ConversationFaqService, generate_and_deduplicate: [])

    allow(Captain::Llm::ContactNotesService).to receive(:new).and_return(contact_notes_service)
    allow(Captain::Llm::ConversationFaqService).to receive(:new).and_return(faq_service)

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
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: voice_token) do
        post '/internal/voice/ai/finalize',
             params: payload,
             headers: {
               'Authorization' => "Bearer #{voice_token}",
               'X-Idempotency-Key' => 'evt-finalize-captain-features-1'
             },
             as: :json
      end
      expect(response).to have_http_status(:ok)
    end

    expect(Captain::Llm::ContactNotesService).to have_received(:new).once.with(assistant, conversation)
    expect(contact_notes_service).to have_received(:generate_and_update_notes).once
    expect(Captain::Llm::ConversationFaqService).to have_received(:new).once.with(assistant, conversation)
    expect(faq_service).to have_received(:generate_and_deduplicate).once
    expect(call_session.reload.metadata.dig('ai_voice', 'post_call_captain_features')).to include(
      'memory' => include('completed_at' => be_present, 'assistant_id' => assistant.id),
      'faq' => include('completed_at' => be_present, 'assistant_id' => assistant.id)
    )
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

    expect(Captain::Llm::ContactNotesService).to have_received(:new).once.with(assistant, conversation)
    expect(contact_notes_service).to have_received(:generate_and_update_notes).once
    expect(Captain::Llm::ConversationFaqService).to have_received(:new).twice.with(assistant, conversation)
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

    expect(Captain::Llm::ConversationFaqService).to have_received(:new).once.with(assistant, conversation)
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

    expect(response).to have_http_status(:ok)
    expect(Captain::Llm::ContactNotesService).to have_received(:new).once.with(assistant, conversation)
    expect(contact_notes_service).to have_received(:generate_and_update_notes).once
    expect(Captain::Llm::ConversationFaqService).to have_received(:new).once.with(assistant, conversation)
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
    activity_message = conversation.messages.activity.find_by!(source_id: "ai_voice_event:#{call_session.external_call_ref}:tool_started:tool-call-1")
    expect(activity_message.content).to eq('Инструмент faq_lookup запущен')
    expect(activity_message.content_attributes.dig('data', 'metadata')).to include('tool_name' => 'faq_lookup', 'tool_call_id' => 'tool-call-1')
    expect(ai_message.reload.additional_attributes.dig('captain_trace', 'tool_steps').last).to include(
      'tool_name' => 'faq_lookup',
      'event' => 'start',
      'status' => 'running'
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
  end
end
