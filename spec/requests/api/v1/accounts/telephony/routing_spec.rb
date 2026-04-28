require 'rails_helper'

RSpec.describe 'Telephony Routing API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: voice_phone_number) }
  let(:voice_phone_number) { "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}" }
  let(:voice_inbox) { voice_channel.inbox }
  let(:number_binding) { voice_inbox.telephony_number_binding }
  let(:path) { "/api/v1/accounts/#{account.id}/telephony/ai/toggle" }
  let(:update_path) { "/api/v1/accounts/#{account.id}/telephony/numbers/#{number_binding.number_ref}/route" }

  before do
    account.enable_features!('channel_voice')
  end

  it 'restores operator routing with fallback_agent_aor when ai is disabled' do
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-app-ref',
      operator_agent_aor: 'sip:1001@example.test',
      settings: { 'last_non_ai_mode' => 'operator' }
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/ai/toggle')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body).to include(
            'number_ref' => number_binding.number_ref,
            'enabled' => false,
            'ai_app_ref' => 'ai-app-ref',
            'fallback_mode' => 'operator',
            'fallback_agent_aor' => 'sip:1001@example.test'
          )
          true
        end
        .to_return(
          status: 200,
          body: {
            numberRef: number_binding.number_ref,
            enabled: false,
            appliedMode: 'operator'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post path,
           params: {
             number_ref: number_binding.number_ref,
             enabled: false
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'routing_policy', 'mode')).to eq('operator')
  end

  it 'falls back to the primary app when ai is disabled without an operator route' do
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-app-ref',
      operator_agent_aor: nil,
      settings: {}
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/ai/toggle')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body).to include(
            'number_ref' => number_binding.number_ref,
            'enabled' => false,
            'ai_app_ref' => 'ai-app-ref',
            'fallback_mode' => 'app',
            'fallback_app_ref' => number_binding.configured_app_ref
          )
          true
        end
        .to_return(
          status: 200,
          body: {
            numberRef: number_binding.number_ref,
            enabled: false,
            appliedMode: 'app'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post path,
           params: {
             number_ref: number_binding.number_ref,
             enabled: false
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'routing_policy', 'mode')).to eq('app')
  end

  it 'maps unsupported voicemail routing to a safe bridge reject without changing the stored policy mode' do
    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, "https://bridge.example/telephony/numbers/#{number_binding.number_ref}/route")
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body).to include(
            'mode' => 'reject',
            'message' => 'Leave a voicemail and we will call back'
          )
          true
        end
        .to_return(
          status: 200,
          body: {
            ref: number_binding.number_ref,
            mode: 'reject'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post update_path,
           params: {
             mode: 'voicemail',
             fallback_message: 'Leave a voicemail and we will call back'
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(number_binding.reload.routing_policy.mode).to eq('voicemail')
    expect(response.parsed_body.dig('payload', 'routing_policy', 'mode')).to eq('voicemail')
    expect(response.parsed_body.dig('meta', 'bridge', 'mode')).to eq('reject')
  end

  it 'resolves operator agent aor from agent_ref when syncing route updates to the bridge' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_ref: 'fonoster-agent-1',
      agent_aor: 'sip:1004@example.test'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, "https://bridge.example/telephony/numbers/#{number_binding.number_ref}/route")
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body).to include(
            'mode' => 'operator',
            'agent_aor' => 'sip:1004@example.test'
          )
          true
        end
        .to_return(
          status: 200,
          body: {
            ref: number_binding.number_ref,
            mode: 'operator'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post update_path,
           params: {
             mode: 'operator',
             operator_agent_ref: agent_binding.agent_ref
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(number_binding.reload.routing_policy.operator_agent_ref).to eq('fonoster-agent-1')
    expect(response.parsed_body.dig('payload', 'routing_policy', 'mode')).to eq('operator')
  end

  it 'syncs SIP operator targets as bridge agent AORs' do
    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, "https://bridge.example/telephony/numbers/#{number_binding.number_ref}/route")
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body).to include(
            'mode' => 'operator',
            'agent_aor' => 'sip:operator1@example.test'
          )
          expect(body).not_to have_key('destination')
          true
        end
        .to_return(
          status: 200,
          body: {
            ref: number_binding.number_ref,
            mode: 'operator'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post update_path,
           params: {
             mode: 'operator',
             operator_agent_aor: 'sip:operator1@example.test'
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(number_binding.reload.routing_policy.operator_agent_aor).to eq('sip:operator1@example.test')
  end

  it 'syncs OneLink-managed AI voice app ref to the bridge while preserving legacy Fonoster fallback' do
    assistant = create(:captain_assistant, account: account)

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, "https://bridge.example/telephony/numbers/#{number_binding.number_ref}/route")
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body).to include(
            'mode' => 'ai',
            'app_ref' => 'onelink-ai-voice-app'
          )
          true
        end
        .to_return(
          status: 200,
          body: {
            ref: number_binding.number_ref,
            mode: 'ai',
            appRef: 'onelink-ai-voice-app'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post update_path,
           params: {
             mode: 'ai',
             ai_deployment_mode: 'onelink_managed',
             ai_app_ref: 'legacy-fonoster-ai-app',
             fonoster_ai_app_ref: 'legacy-fonoster-ai-app',
             onelink_ai_app_ref: 'onelink-ai-voice-app',
             fallback_ai_app_ref: 'fallback-ai-app',
             captain_assistant_id: assistant.id,
             ai_voice_settings: {
               provider: 'gemini-live',
               language: 'ru-KZ',
               interruptions_enabled: true
             }
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    policy_payload = response.parsed_body.dig('payload', 'routing_policy')
    expect(policy_payload).to include(
      'mode' => 'ai',
      'ai_deployment_mode' => 'onelink_managed',
      'ai_app_ref' => 'legacy-fonoster-ai-app',
      'fonoster_ai_app_ref' => 'legacy-fonoster-ai-app',
      'onelink_ai_app_ref' => 'onelink-ai-voice-app',
      'effective_ai_app_ref' => 'onelink-ai-voice-app',
      'captain_assistant_id' => assistant.id
    )
    expect(policy_payload.dig('ai_voice_settings', 'language')).to eq('ru-KZ')
    expect(number_binding.reload.app_ref).to eq('onelink-ai-voice-app')
  end

  it 'rejects a captain assistant from another account' do
    other_assistant = create(:captain_assistant)

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      post update_path,
           params: {
             mode: 'ai',
             ai_deployment_mode: 'onelink_managed',
             onelink_ai_app_ref: 'onelink-ai-voice-app',
             captain_assistant_id: other_assistant.id
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:unprocessable_content)
    expect(number_binding.reload.routing_policy.captain_assistant_id).to be_nil
  end

  it 'updates the primary app ref through the number route endpoint' do
    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, "https://bridge.example/telephony/numbers/#{number_binding.number_ref}/route")
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body).to include(
            'mode' => 'app',
            'app_ref' => 'business-app-ref'
          )
          true
        end
        .to_return(
          status: 200,
          body: {
            ref: number_binding.number_ref,
            mode: 'app',
            appRef: 'business-app-ref'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post update_path,
           params: {
             mode: 'app',
             app_ref: 'business-app-ref',
             fallback_mode: 'reject'
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(number_binding.reload.configured_app_ref).to eq('business-app-ref')
    expect(voice_channel.reload.provider_config['app_ref']).to eq('business-app-ref')
    expect(response.parsed_body.dig('payload', 'app_ref')).to eq('business-app-ref')
  end

  it 'persists ai fallback settings for operator routes' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_ref: 'fonoster-agent-ai-fallback',
      agent_aor: 'sip:1006@example.test'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, "https://bridge.example/telephony/numbers/#{number_binding.number_ref}/route")
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body).to include(
            'mode' => 'operator',
            'agent_aor' => 'sip:1006@example.test'
          )
          true
        end
        .to_return(
          status: 200,
          body: {
            ref: number_binding.number_ref,
            mode: 'operator'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post update_path,
           params: {
             mode: 'operator',
             operator_agent_ref: agent_binding.agent_ref,
             ai_app_ref: 'ai-fallback-app-ref',
             fallback_mode: 'ai'
           },
           headers: headers,
           as: :json
    end

    policy = number_binding.reload.routing_policy
    expect(response).to have_http_status(:ok)
    expect(policy.mode).to eq('operator')
    expect(policy.fallback_mode).to eq('ai')
    expect(policy.ai_app_ref).to eq('ai-fallback-app-ref')
    expect(voice_channel.reload.provider_config['fallback_mode']).to eq('ai')
    expect(voice_channel.provider_config['ai_app_ref']).to eq('ai-fallback-app-ref')
  end

  it 'restores a safe app route when ai is disabled after an unsupported non-ai mode' do
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-app-ref',
      operator_agent_aor: nil,
      settings: { 'last_non_ai_mode' => 'voicemail' }
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/ai/toggle')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body).to include(
            'number_ref' => number_binding.number_ref,
            'enabled' => false,
            'ai_app_ref' => 'ai-app-ref',
            'fallback_mode' => 'app',
            'fallback_app_ref' => number_binding.configured_app_ref
          )
          true
        end
        .to_return(
          status: 200,
          body: {
            numberRef: number_binding.number_ref,
            enabled: false,
            appliedMode: 'app'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post path,
           params: {
             number_ref: number_binding.number_ref,
             enabled: false
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(number_binding.reload.routing_policy.mode).to eq('app')
    expect(response.parsed_body.dig('payload', 'routing_policy', 'mode')).to eq('app')
  end

  it 'restores operator routing from agent_ref-only configuration when ai is disabled' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_ref: 'fonoster-agent-2',
      agent_aor: 'sip:1005@example.test'
    )

    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-app-ref',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: nil,
      settings: { 'last_non_ai_mode' => 'operator' }
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/ai/toggle')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .with do |request|
          body = JSON.parse(request.body)
          expect(body).to include(
            'number_ref' => number_binding.number_ref,
            'enabled' => false,
            'ai_app_ref' => 'ai-app-ref',
            'fallback_mode' => 'operator',
            'fallback_agent_aor' => 'sip:1005@example.test'
          )
          true
        end
        .to_return(
          status: 200,
          body: {
            numberRef: number_binding.number_ref,
            enabled: false,
            appliedMode: 'operator'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post path,
           params: {
             number_ref: number_binding.number_ref,
             enabled: false
           },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(number_binding.reload.routing_policy.mode).to eq('operator')
    expect(response.parsed_body.dig('payload', 'routing_policy', 'mode')).to eq('operator')
  end
end
