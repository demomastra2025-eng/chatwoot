require 'rails_helper'

RSpec.describe 'Internal Voice AI Control API', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+15550000004') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:conversation) { create(:conversation, account: account, inbox: voice_inbox) }
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: 'ai-control-call-1',
      status: 'in_progress'
    )
  end

  before do
    account.enable_features!('channel_voice')
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    call_session
  end

  it 'records bounded control events in call metadata' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: { call_ref: call_session.external_call_ref, account_id: account.id, action: 'caller_interrupted',
                     metadata: { provider: 'gemini-live' } },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload.metadata.dig('ai_voice', 'control_events').last).to include(
      'action' => 'caller_interrupted',
      'metadata' => { 'provider' => 'gemini-live' }
    )
  end

  it 'accepts explicit AI voice terminal lifecycle reasons' do
    %w[caller_hangup media_stream_closed provider_stream_closed provider_error provider_call_closed runtime_closed].each do |action|
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/control',
             params: { call_ref: call_session.external_call_ref, account_id: account.id, action: action,
                       metadata: { reason: action } },
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
      end

      expect(response).to have_http_status(:ok)
    end

    expect(call_session.reload.metadata.dig('ai_voice', 'control_events').last(6).pluck('action')).to eq(
      %w[caller_hangup media_stream_closed provider_stream_closed provider_error provider_call_closed runtime_closed]
    )
  end

  it 'renders AI pickup lifecycle events with the product label' do
    %w[ai_ringing ai_answered].each do |action|
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/control',
             params: { call_ref: call_session.external_call_ref, account_id: account.id, action: action },
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
      end

      expect(response).to have_http_status(:ok)
    end

    event_messages = conversation.messages.where('source_id LIKE ?', "ai_voice_event:#{call_session.external_call_ref}:ai_%").order(:id)

    expect(event_messages.pluck(:content)).to eq(['AI-агент принимает звонок', 'AI-агент ответил на звонок'])
  end

  it 'keeps high-frequency voice observability out of the conversation timeline' do
    actions = Telephony::AiVoice::ConversationTimelineService::INTERNAL_OBSERVABILITY_ACTIONS
    allow(Telephony::AiVoice::ConversationTimelineService).to receive(:new).and_call_original

    actions.each do |action|
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/control',
             params: { call_ref: call_session.external_call_ref, account_id: account.id, action: action },
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
      end

      expect(response).to have_http_status(:ok)
    end

    expect(call_session.reload.metadata.dig('ai_voice', 'control_events').last(actions.size).pluck('action')).to eq(actions)
    expect(conversation.messages.activity.where('source_id LIKE ?', "ai_voice_event:#{call_session.external_call_ref}:%")).not_to exist
    expect(Telephony::AiVoice::ConversationTimelineService).not_to have_received(:new)
  end

  it 'attaches voice tool input and output details to the AI transcript trace' do
    create(
      :message,
      account: account,
      inbox: voice_inbox,
      conversation: conversation,
      message_type: :outgoing,
      content: 'AI answer',
      source_id: "ai_voice_turn:#{call_session.external_call_ref}:0001:ai",
      content_attributes: { data: { type: 'ai_voice_transcript_turn', speaker: 'ai' } }
    )

    [
      ['tool_started', { tool_name: 'faq_lookup', tool_call_id: 'tool-call-1', input: { question: 'Price?', access_token: 'x' } }],
      ['tool_progress', { tool_name: 'faq_lookup', tool_call_id: 'tool-call-1', output: { status: 'searching' } }],
      ['tool_completed', { tool_name: 'faq_lookup', tool_call_id: 'tool-call-1', output: { answer: 'Found', api_key: 'x' } }],
      ['tool_suppressed', { tool_name: 'faq_lookup', tool_call_id: 'tool-call-1', duplicate: true }]
    ].each do |action, metadata|
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/control',
             params: { call_ref: call_session.external_call_ref, account_id: account.id, action: action, metadata: metadata },
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
      end

      expect(response).to have_http_status(:ok)
    end

    expect(conversation.messages.activity.where('source_id LIKE ?', "ai_voice_event:#{call_session.external_call_ref}:tool_%")).not_to exist
    stored_tool_events = call_session.reload.metadata.dig('ai_voice', 'control_events')
    expect(stored_tool_events.first.dig('metadata', 'input', 'access_token')).to eq('[REDACTED]')
    expect(stored_tool_events.third.dig('metadata', 'output', 'api_key')).to eq('[REDACTED]')
    ai_message = conversation.messages.find_by!(source_id: "ai_voice_turn:#{call_session.external_call_ref}:0001:ai")
    tool_steps = ai_message.additional_attributes.dig('captain_trace', 'tool_steps')

    expect(tool_steps).to contain_exactly(
      include(
        'type' => 'captain_tool_event',
        'tool_name' => 'faq_lookup',
        'event' => 'start',
        'status' => 'start',
        'input' => { 'question' => 'Price?', 'access_token' => '[REDACTED]' }
      ),
      include(
        'type' => 'captain_tool_event',
        'tool_name' => 'faq_lookup',
        'event' => 'progress',
        'status' => 'progress',
        'output' => { 'status' => 'searching' }
      ),
      include(
        'type' => 'captain_tool_event',
        'tool_name' => 'faq_lookup',
        'event' => 'finish',
        'status' => 'finish',
        'output' => { 'answer' => 'Found', 'api_key' => '[REDACTED]' }
      ),
      include(
        'type' => 'captain_tool_event',
        'tool_name' => 'faq_lookup',
        'event' => 'suppressed',
        'status' => 'suppressed'
      )
    )
  end

  it 'scopes control mutations by account_id when call_ref collides across accounts' do
    other_account = create(:account)
    other_session = create(:telephony_call_session, account: other_account, external_call_ref: 'shared-control-call-ref', status: 'in_progress')
    target_session = create(:telephony_call_session, account: account, external_call_ref: 'shared-control-call-ref', status: 'in_progress')

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: { call_ref: 'shared-control-call-ref', account_id: account.id, action: 'caller_interrupted' },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(target_session.reload.metadata.dig('ai_voice', 'control_events').last['action']).to eq('caller_interrupted')
    expect(other_session.reload.metadata.dig('ai_voice', 'control_events')).to be_blank
  end

  it 'does not fall back to unscoped lookup when account_id is invalid' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: { call_ref: call_session.external_call_ref, account_id: -1, action: 'caller_interrupted' },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:not_found)
    expect(call_session.reload.metadata.dig('ai_voice', 'control_events')).to be_blank
  end

  it 'does not mutate a call session through an unscoped call_ref' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: { call_ref: call_session.external_call_ref, action: 'caller_interrupted' },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:not_found)
    expect(call_session.reload.metadata.dig('ai_voice', 'control_events')).to be_blank
  end

  it 'replays a lifecycle control retry without duplicating durable events' do
    params = {
      call_ref: call_session.external_call_ref,
      account_id: account.id,
      action: 'tool_completed',
      event_key: 'pipecat-control:runtime-1:7:tool_completed',
      metadata: { tool_call_id: 'tool-1', tool_name: 'faq_lookup' }
    }

    perform_enqueued_jobs do
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        2.times do
          post '/internal/voice/ai/control',
               params: params,
               headers: { 'Authorization' => 'Bearer voice-secret' },
               as: :json
          expect(response).to have_http_status(:ok)
        end
      end
    end

    control_events = call_session.reload.metadata.dig('ai_voice', 'control_events')
    expect(control_events.count { |event| event['event_key'] == params[:event_key] }).to eq(1)
    expect(account.telephony_events.where(event_key: params[:event_key]).count).to eq(1)
    expect(response.parsed_body).to include('idempotent' => true)
  end

  it 'discards a tool progress callback that arrives after the same tool completed' do
    completed_params = {
      call_ref: call_session.external_call_ref,
      account_id: account.id,
      action: 'tool_completed',
      event_key: 'pipecat-control:runtime-1:10:tool_completed',
      metadata: { tool_call_id: 'tool-stale-progress', tool_name: 'faq_lookup' }
    }
    progress_params = {
      call_ref: call_session.external_call_ref,
      account_id: account.id,
      action: 'tool_progress',
      event_key: 'pipecat-control:runtime-1:11:tool_progress',
      metadata: { tool_call_id: 'tool-stale-progress', tool_name: 'faq_lookup', stage: 'delayed' }
    }

    perform_enqueued_jobs do
      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        post '/internal/voice/ai/control',
             params: completed_params,
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
        expect(response).to have_http_status(:ok)

        post '/internal/voice/ai/control',
             params: progress_params,
             headers: { 'Authorization' => 'Bearer voice-secret' },
             as: :json
      end
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('stale' => true)
    tool_events = call_session.reload.metadata.dig('ai_voice', 'control_events')
    expect(tool_events.pluck('action')).to include('tool_completed')
    expect(tool_events.pluck('action')).not_to include('tool_progress')
    expect(account.telephony_events.find_by(event_key: progress_params[:event_key])).to be_nil
  end

  it 'replays idempotent downstream delivery after a partial timeline failure' do
    params = {
      call_ref: call_session.external_call_ref,
      account_id: account.id,
      action: 'ai_answered',
      event_key: 'pipecat-control:runtime-1:8:ai_answered'
    }
    attempts = 0
    allow_any_instance_of(Telephony::AiVoice::ConversationTimelineService)
      .to receive(:record_control_event!).and_wrap_original do |method, *args, **kwargs|
      attempts += 1
      raise ActiveRecord::ConnectionTimeoutError, 'temporary timeline failure' if attempts == 1

      method.call(*args, **kwargs)
    end

    expect { Telephony::AiVoice::ControlService.new(payload: params).perform }
      .to raise_error(ActiveRecord::ConnectionTimeoutError)

    result = Telephony::AiVoice::ControlService.new(payload: params).perform

    expect(result).to include(status: 'ok', idempotent: true)
    expect(attempts).to eq(2)
    expect(call_session.reload.metadata.dig('ai_voice', 'control_events').count { |event| event['event_key'] == params[:event_key] }).to eq(1)
    expect(account.telephony_events.where(event_key: params[:event_key]).count).to eq(1)
  end

  it 'falls back to synchronous lifecycle ingestion when enqueue fails' do
    allow(Telephony::InboundRouteLifecycleJob).to receive(:perform_later)
      .and_raise(ActiveJob::EnqueueError, 'redis down')

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      post '/internal/voice/ai/control',
           params: {
             call_ref: call_session.external_call_ref,
             account_id: account.id,
             action: 'tool_completed',
             event_key: 'pipecat-control:runtime-1:9:tool_completed',
             metadata: { tool_call_id: 'tool-2', tool_name: 'faq_lookup' }
           },
           headers: { 'Authorization' => 'Bearer voice-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(account.telephony_events.find_by!(event_key: 'pipecat-control:runtime-1:9:tool_completed')).to be_processed
  end
end
