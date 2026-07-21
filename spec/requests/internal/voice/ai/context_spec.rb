require 'rails_helper'

RSpec.describe 'Internal Voice AI Context API', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+15551230001') }
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

  it 'accepts the dedicated Pipecat callback token' do
    with_modified_env(ONELINK_AI_VOICE_PIPECAT_CALLBACK_TOKEN: 'pipecat-callback-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer pipecat-callback-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
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
      'interruption_mode' => 'transcript_confirmed',
      'clear_audio_on_interrupt' => true,
      'turn_coverage' => 'TURN_INCLUDES_ONLY_ACTIVITY',
      'humanlike_defaults_profile' => 'standard_v1',
      'finish_current_word_on_interrupt' => true,
      'post_interrupt_micro_pause_ms' => 180,
      'interrupt_ack_phrases' => ['Ага.', 'Понял.', 'Мм.', 'Аха.', 'А-а, понял.'],
      'silence_prompt_enabled' => true,
      'tool_start_phrases' => ['Секунду, проверю.'],
      'tool_start_after_ms' => 1800,
      'tool_foreground_wait_ms' => 900,
      'emotional_style' => 'warm_professional',
      'nonverbal_cues_enabled' => true,
      'ambient_noise_enabled' => false,
      'max_output_tokens' => 1024,
      'max_duration_sec' => 600
    )
    system_prompt = body.dig('ai', 'system_prompt')
    expect(system_prompt).to include('Ты голосовой ассистент в телефонном звонке')
    expect(system_prompt).not_to include('Voice character prompt')
    expect(body['ai']).not_to have_key('voice_character_prompt')
    expect(system_prompt).to include('Отвечай максимум 1-2 короткими предложениями')
    expect(system_prompt).to include('Answer callers using OneLink account context.')
    expect(system_prompt).to include('Answer shortly')
    expect(system_prompt).to include('Do not reveal private data')
    expect(system_prompt).to include('Voice Response Contract')
    expect(system_prompt).to include('realtime AUDIO phone session')
    expect(system_prompt).not_to include('Final Response Contract')
    expect(system_prompt).not_to include('Return only a valid JSON object')
    expect(system_prompt).not_to include('Use this shape')
    expect(system_prompt).not_to include('artifact_ids')
    expect(body.dig('captain', 'assistant_id')).to eq(assistant.id)
    expect(body.dig('captain', 'system_prompt')).to include('Answer callers using OneLink account context.')
    expect(body.dig('transfer', 'operator_agent_aor')).to eq('sip:1001@example.test')
    expect(body['recording']).to include(
      'enabled' => true,
      'source' => 'onelink_runtime',
      'storage_provider' => 'onelink_storage'
    )
    expect(body['tools'].pluck('name')).to include('find_contact', 'create_note', 'request_transfer', 'end_call')
    end_call_tool = body['tools'].find { |tool| tool['name'] == 'end_call' }
    expect(end_call_tool['timeout_ms']).to be >= 5000
  end

  [
    ['openai-realtime', 'gpt-realtime-2', 'alloy'],
    ['elevenlabs', 'openai/gpt-5.4-mini', 'Xb7hH8MSUJpSbSDYk0k2']
  ].each do |provider, model, voice|
    it "returns #{provider} provider settings without applying Gemini defaults" do
      assistant.update!(
        config: assistant.config.merge(
          'voice_settings' => {
            'provider' => provider,
            'model' => model,
            'voice' => voice
          }
        )
      )

      with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
        get '/internal/voice/ai/context',
            params: { call_ref: call_session.external_call_ref, account_id: account.id },
            headers: { 'Authorization' => 'Bearer voice-secret' },
            as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['ai']).to include(
        'provider' => provider,
        'model' => model,
        'voice' => voice
      )
    end
  end

  it 'preserves outbound provider and transport metadata for existing call sessions' do
    contact = create(:contact, :with_phone_number, account: account)
    conversation = create(:conversation, account: account, inbox: voice_inbox, contact: contact)
    outbound_session = create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      contact: contact,
      inbox: voice_inbox,
      number_binding: number_binding,
      external_call_ref: 'sipuni-ai-outbound-1',
      provider: 'sipuni',
      direction: 'outbound',
      from_number: voice_channel.phone_number,
      to_number: contact.phone_number,
      metadata: { 'ai_voice' => { 'transport' => 'janus_sip' } }
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: outbound_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body).to include(
      'call_ref' => 'sipuni-ai-outbound-1',
      'provider' => 'sipuni',
      'direction' => 'outbound',
      'caller_number' => voice_channel.phone_number,
      'ingress_number' => contact.phone_number
    )
    expect(body['transport']).to include(
      'provider' => 'sipuni',
      'direction' => 'outbound',
      'media' => 'janus_sip'
    )
  end

  it 'adds a separate voice character prompt block to the generated voice prompt' do
    voice_character_prompt = 'Тембр: тёплый эксперт-наставник. Темп спокойный, без смеха.'

    number_binding.routing_policy.update!(
      ai_voice_settings: number_binding.routing_policy.ai_voice_settings.merge(
        system_prompt: 'Основной сценарий звонка: помогай с записью.',
        voice_character_prompt: voice_character_prompt
      )
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    system_prompt = body.dig('ai', 'system_prompt')

    expect(body.dig('ai', 'voice_character_prompt')).to eq(voice_character_prompt)
    expect(system_prompt).to include("Voice character prompt:\n#{voice_character_prompt}")
    expect(system_prompt.index('Основной сценарий звонка')).to be < system_prompt.index('Voice character prompt')
    expect(system_prompt.index('Voice character prompt')).to be < system_prompt.index('Ты голосовой ассистент')
  end

  it 'returns enabled Captain scenarios in the voice runtime context' do
    enabled_scenario = create(
      :captain_scenario,
      account: account,
      assistant: assistant,
      title: 'Pricing handoff',
      description: 'Collect budget and product interest before transfer.'
    )
    later_enabled_scenario = create(
      :captain_scenario,
      account: account,
      assistant: assistant,
      title: 'Support handoff',
      description: 'Route technical support questions after collecting account context.'
    )
    create(
      :captain_scenario,
      account: account,
      assistant: assistant,
      title: 'Disabled scenario',
      enabled: false
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    scenarios = response.parsed_body.dig('captain', 'scenarios')
    expect(scenarios.pluck('id')).to eq([enabled_scenario.id, later_enabled_scenario.id])
    expect(scenarios.first).to include(
      'id' => enabled_scenario.id,
      'title' => 'Pricing handoff',
      'key' => enabled_scenario.handoff_key,
      'description' => 'Collect budget and product interest before transfer.'
    )
    expect(scenarios.pluck('title')).not_to include('Disabled scenario')
  end

  it 'uses the fast Captain voice prompt by default for low-latency calls' do
    builder = Telephony::AiVoice::ContextBuilder.new(
      params: { call_ref: call_session.external_call_ref, account_id: account.id }
    )
    resolved_assistant = builder.send(:captain_assistant)
    expect(builder).not_to receive(:captain_runtime_state_for_prompt)
    expect(resolved_assistant).not_to receive(:agent_instructions)

    system_prompt = builder.send(:system_prompt)

    expect(system_prompt).to include('Answer callers using OneLink account context.')
    expect(system_prompt).to include('Answer shortly')
    expect(system_prompt).to include('Do not reveal private data')
    expect(system_prompt).to include('Current caller context')
    expect(system_prompt).to include('ai-context-call-1')
    expect(system_prompt).to include('Voice Response Contract')
    expect(system_prompt).to include('Ты голосовой ассистент в телефонном звонке')
  end

  it 'builds the full Captain prompt once per voice context request when explicitly enabled' do
    builder = Telephony::AiVoice::ContextBuilder.new(
      params: { call_ref: call_session.external_call_ref, account_id: account.id }
    )
    resolved_assistant = builder.send(:captain_assistant)
    expect(resolved_assistant).to receive(:agent_instructions).once.and_call_original

    with_modified_env(VOICE_AGENT_FULL_CAPTAIN_PROMPT: 'true') do
      first_prompt = builder.send(:system_prompt)
      second_prompt = builder.send(:system_prompt)

      expect(first_prompt).to eq(second_prompt)
      expect(first_prompt).to include('Ты голосовой ассистент в телефонном звонке')
    end
  end

  it 'allows voice recording to be disabled explicitly for a route' do
    number_binding.routing_policy.update!(
      ai_voice_settings: number_binding.routing_policy.ai_voice_settings.merge(recording_enabled: false)
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('recording', 'enabled')).to be(false)
  end

  it 'preserves explicit false and zero values in normalized voice settings' do
    number_binding.routing_policy.update!(
      ai_voice_settings: number_binding.routing_policy.ai_voice_settings.merge(
        interruptions_enabled: false,
        clear_audio_on_interrupt: false,
        interruption_mode: 'provider',
        tool_foreground_wait_ms: '0',
        silence_prompt_after_ms: 0,
        nonverbal_cue_max_per_minute: 0
      )
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['ai']).to include(
      'interruptions_enabled' => false,
      'clear_audio_on_interrupt' => false,
      'interruption_mode' => 'provider',
      'tool_foreground_wait_ms' => 0,
      'silence_prompt_after_ms' => 0,
      'nonverbal_cue_max_per_minute' => 0
    )
  end

  it 'falls back to standard defaults when persisted voice settings contain blank values' do
    number_binding.routing_policy.update!(
      ai_voice_settings: number_binding.routing_policy.ai_voice_settings.merge(
        provider: '',
        model: nil,
        voice: ' ',
        first_message: '',
        max_duration_sec: ''
      )
    )

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['ai']).to include(
      'provider' => 'gemini-live',
      'model' => 'gemini-3.1-flash-live-preview',
      'voice' => 'sulafat',
      'first_message' => 'Здравствуйте! Чем могу помочь?',
      'max_duration_sec' => 900
    )
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

  it 'returns a bounded realtime timeout for FAQ lookup in the tool catalog' do
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
    expect(faq_tool).to include('source' => 'captain', 'timeout_ms' => 10_000, 'foreground_wait_ms' => 900)
  end

  it 'returns prompt-referenced Captain CRM tools for the voice runtime catalog' do
    crm_assistant = create(
      :captain_assistant,
      account: account,
      description: [
        'Use [@Создать сделку](tool://create_deal) when the caller asks for a deal.',
        'Use [@Обновить сделку](tool://update_deal) when the caller changes deal data.',
        'Use [@Перевести сделку](tool://transition_deal_stage) when stage changes are requested.'
      ].join(' '),
      config: {
        tool_access: {
          agent: {
            enabled: true,
            tool_ids: ['faq_lookup']
          }
        }
      }
    )
    create(:captain_inbox, captain_assistant: crm_assistant, inbox: voice_inbox)

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get '/internal/voice/ai/context',
          params: { call_ref: call_session.external_call_ref, account_id: account.id },
          headers: { 'Authorization' => 'Bearer voice-secret' },
          as: :json
    end

    expect(response).to have_http_status(:ok)
    tool_names = response.parsed_body['tools'].pluck('name')
    expect(tool_names).to include(
      'create_deal',
      'update_deal',
      'transition_deal_stage',
      'get_deal',
      'search_deals',
      'list_deal_pipelines',
      'list_deal_stages'
    )
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
    other_voice_channel = create(:channel_voice, :sipuni, account: other_account, phone_number: '+1555889020')
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

  it 'accepts the native SIP contract shared secret alias' do
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
