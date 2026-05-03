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
    expect(conversation.messages.where(source_id: "ai_voice_transcript:#{call_session.external_call_ref}")).to exist
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
end
