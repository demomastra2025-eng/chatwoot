require 'rails_helper'

RSpec.describe 'Internal Voice AI Context API', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: '+15551230001') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:number_binding) { voice_inbox.telephony_number_binding }
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      name: 'Voice Captain',
      description: 'Answer callers using OneLink account context.',
      response_guidelines: ['Answer shortly'],
      guardrails: ['Do not reveal private data']
    )
  end
  let(:call_session) do
    create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      external_call_ref: 'ai-context-call-1',
      direction: 'inbound',
      from_number: '+15559990000',
      to_number: voice_channel.phone_number
    )
  end

  before do
    account.enable_features!('channel_voice')
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_deployment_mode: 'onelink_managed',
      ai_app_ref: 'legacy-fonoster-ai-app',
      fonoster_ai_app_ref: 'legacy-fonoster-ai-app',
      onelink_ai_app_ref: 'onelink-ai-voice-app',
      fallback_ai_app_ref: 'fallback-ai-app',
      captain_assistant: assistant,
      operator_agent_aor: 'sip:1001@example.test',
      ai_voice_settings: {
        provider: 'gemini-live',
        model: 'gemini-2.0-flash-live-001',
        voice: 'Puck',
        language: 'ru-KZ',
        first_message: 'Здравствуйте! Чем могу помочь?',
        max_duration_sec: 600,
        interruptions_enabled: true
      }
    )
    call_session
  end

  it 'requires the internal voice token' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context', params: { call_ref: call_session.external_call_ref }, as: :json
    end

    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns low-latency context for the OneLink managed voice service' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body).to include(
      'call_ref' => 'ai-context-call-1',
      'account_id' => account.id,
      'conversation_id' => call_session.conversation_id,
      'contact_id' => call_session.contact_id,
      'inbox_id' => voice_inbox.id,
      'number_ref' => number_binding.number_ref
    )
    expect(body['ai']).to include(
      'deployment_mode' => 'onelink_managed',
      'app_ref' => 'onelink-ai-voice-app',
      'provider' => 'gemini-live',
      'model' => 'gemini-2.0-flash-live-001',
      'voice' => 'Puck',
      'language' => 'ru-KZ',
      'first_message' => 'Здравствуйте! Чем могу помочь?',
      'interruptions_enabled' => true,
      'max_duration_sec' => 600
    )
    expect(body.dig('ai', 'system_prompt')).to include('Ты голосовой ассистент в телефонном звонке')
    expect(body.dig('ai', 'system_prompt')).to include('Отвечай максимум 1-2 короткими предложениями')
    expect(body.dig('captain', 'assistant_id')).to eq(assistant.id)
    expect(body.dig('captain', 'system_prompt')).to include('Answer callers using OneLink account context.')
    expect(body.dig('transfer', 'operator_agent_aor')).to eq('sip:1001@example.test')
    expect(body['tools'].pluck('name')).to include('find_contact', 'create_note', 'request_transfer', 'end_call')
  end

  it 'uses the inbox Captain assistant as the voice brain and preserves voice default tools' do
    captain_tool = create(
      :captain_custom_tool,
      account: account,
      title: 'Lookup booking',
      description: 'Find a booking by booking code',
      param_schema: [
        { 'name' => 'booking_code', 'type' => 'string', 'description' => 'Booking code', 'required' => true }
      ]
    )
    inbox_assistant = create(
      :captain_assistant,
      account: account,
      name: 'Inbox Voice Captain',
      description: "Speak as the connected inbox Captain. Use [Lookup booking](tool://#{captain_tool.slug}) when needed.",
      response_guidelines: ['Voice answers must be short.'],
      config: {
        voice_settings: {
          provider: 'gemini-live',
          model: 'gemini-3.1-flash-live-preview',
          voice: 'sulafat',
          language: 'ru-KZ',
          system_prompt: 'Говори как ресепшен клиники и не перечисляй списками.',
          first_message: 'Сәлеметсіз бе! Қалай көмектесемін?',
          max_duration_sec: 450,
          interruptions_enabled: false,
          transfer_message: 'Қазір операторға қосамын.'
        },
        tool_access: {
          agent: {
            enabled: true,
            tool_ids: [captain_tool.slug]
          }
        }
      }
    )
    create(:captain_inbox, captain_assistant: inbox_assistant, inbox: voice_inbox)
    number_binding.routing_policy.update!(
      captain_assistant: nil,
      ai_voice_settings: {
        provider: 'legacy-provider',
        model: 'legacy-model',
        voice: 'legacy-voice',
        first_message: 'Legacy greeting',
        transfer_message: 'Legacy transfer'
      }
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.dig('captain', 'assistant_id')).to eq(inbox_assistant.id)
    expect(body.dig('captain', 'system_prompt')).to include('connected inbox Captain')
    expect(body['ai']).to include(
      'provider' => 'gemini-live',
      'model' => 'gemini-3.1-flash-live-preview',
      'voice' => 'sulafat',
      'system_prompt' => a_string_including('Говори как ресепшен клиники'),
      'first_message' => 'Сәлеметсіз бе! Қалай көмектесемін?',
      'interruptions_enabled' => false,
      'max_duration_sec' => 450
    )
    expect(body.dig('transfer', 'message')).to eq('Қазір операторға қосамын.')

    tool_names = body['tools'].pluck('name')
    expect(tool_names).to include('end_call', 'request_transfer', captain_tool.slug)
    booking_tool = body['tools'].find { |tool| tool['name'] == captain_tool.slug }
    expect(booking_tool).to include(
      'source' => 'captain',
      'scope' => 'agent',
      'description' => 'Find a booking by booking code'
    )
    expect(booking_tool.dig('parameters', 'properties', 'booking_code', 'type')).to eq('string')
  end

  it 'returns a longer timeout for realtime FAQ lookup in the tool catalog' do
    faq_assistant = create(
      :captain_assistant,
      account: account,
      config: {
        tool_access: {
          agent: {
            enabled: true,
            tool_ids: ['faq_lookup']
          }
        }
      }
    )
    create(:captain_inbox, captain_assistant: faq_assistant, inbox: voice_inbox)

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    faq_tool = response.parsed_body['tools'].find { |tool| tool['name'] == 'faq_lookup' }
    expect(faq_tool).to include('source' => 'captain', 'timeout_ms' => 6000)
  end

  it 'does not resolve context from an unscoped call_ref even when it is globally unique' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body['error']).to eq('CALL_SESSION_NOT_FOUND')
  end

  it 'does not create a native session from account_id alone when call_ref is unresolved' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: 'account-only-unresolved-call', account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body['error']).to eq('CALL_SESSION_NOT_FOUND')
    expect(account.telephony_call_sessions.find_by(external_call_ref: 'account-only-unresolved-call')).to be_nil
  end

  it 'accepts a valid internal token header even when Authorization contains a stale bearer' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: {
            'Authorization' => 'Bearer stale-token',
            'X-Onelink-Internal-Token' => 'voice-secret'
          },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['account_id']).to eq(account.id)
  end

  it 'scopes existing call context by account_id when call_ref collides across accounts' do
    other_account = create(:account)
    create(:telephony_call_session, account: other_account, external_call_ref: 'shared-ai-call-ref')
    target_session = create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      external_call_ref: 'shared-ai-call-ref'
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: 'shared-ai-call-ref', account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'account_id' => account.id,
      'conversation_id' => target_session.conversation_id
    )
  end

  it 'rejects context requests with a number_ref from another account' do
    other_account = create(:account)
    other_voice_channel = create(:channel_voice, :fonoster, account: other_account, phone_number: '+1555889020')
    Telephony::NumberBinding.sync_from_voice_channel!(other_voice_channel)

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: {
            call_ref: call_session.external_call_ref,
            account_id: account.id,
            number_ref: other_voice_channel.inbox.telephony_number_binding.number_ref
          },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('NUMBER_BINDING_ACCOUNT_MISMATCH')
  end

  it 'creates a native inbound call session when the realtime service asks context before events arrive' do
    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: {
            call_ref: 'ai-context-new-call',
            account_id: account.id,
            number_ref: number_binding.number_ref,
            caller_number: '+15558887777',
            ingress_number: voice_channel.phone_number
          },
          headers: { 'X-Onelink-Internal-Token' => 'voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    session = account.telephony_call_sessions.find_by!(external_call_ref: 'ai-context-new-call')
    expect(session).to have_attributes(
      status: 'ringing',
      direction: 'inbound',
      from_number: '+15558887777',
      to_number: voice_channel.phone_number,
      inbox_id: voice_inbox.id,
      number_binding_id: number_binding.id
    )
    expect(response.parsed_body['conversation_id']).to eq(session.conversation_id)
  end

  it 'accepts the Fonoster contract shared secret alias' do
    with_modified_env(VOICE_AGENT_ONELINK_AI_SHARED_SECRET: 'contract-secret') do
      post '/internal/voice/ai/context',
           params: { call_ref: call_session.external_call_ref, account_id: account.id },
           headers: { 'Authorization' => 'Bearer contract-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['account_id']).to eq(account.id)
  end
end
