require 'rails_helper'

RSpec.describe 'Telephony Routing API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: voice_phone_number) }
  let(:voice_phone_number) { "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}" }
  let(:voice_inbox) { voice_channel.inbox }
  let(:number_binding) { voice_inbox.telephony_number_binding }
  let(:toggle_path) { "/api/v1/accounts/#{account.id}/telephony/ai/toggle" }
  let(:update_path) { "/api/v1/accounts/#{account.id}/telephony/numbers/#{number_binding.number_ref}/route" }

  before do
    account.enable_features!('channel_voice')
  end

  it 'restores operator routing locally when AI is disabled' do
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-app-ref',
      operator_agent_aor: 'sip:1001@example.test',
      settings: {
        'last_non_ai_mode' => 'operator',
        'operator_distribution_mode' => 'targeted'
      }
    )

    post toggle_path,
         params: {
           number_ref: number_binding.number_ref,
           enabled: false
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'routing_policy', 'mode')).to eq('operator')
    expect(response.parsed_body.dig('meta', 'janus_sip')).to include(
      'provider' => 'janus_sip',
      'remote_bridge' => false,
      'number_ref' => number_binding.number_ref,
      'ai_enabled' => false
    )
  end

  it 'updates targeted operator routing in local policy and voice channel config' do
    post update_path,
         params: {
           mode: 'operator',
           operator_agent_aor: 'sip:operator1@example.test',
           operator_distribution_mode: 'targeted'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(number_binding.reload.routing_policy).to have_attributes(
      mode: 'operator',
      operator_agent_aor: 'sip:operator1@example.test'
    )
    expect(number_binding.routing_policy.operator_distribution_mode).to eq('targeted')
    expect(voice_channel.reload.provider_config).to include(
      'routing_mode' => 'operator',
      'operator_agent_aor' => 'sip:operator1@example.test',
      'operator_distribution_mode' => 'targeted'
    )
    expect(response.parsed_body.dig('meta', 'janus_sip')).to include('remote_bridge' => false)
  end

  it 'syncs OneLink-managed AI voice policy locally' do
    assistant = create(:captain_assistant, account: account)

    post update_path,
         params: {
           mode: 'ai',
           ai_deployment_mode: 'onelink_managed',
           ai_app_ref: 'local-ai-app',
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

    expect(response).to have_http_status(:ok)
    policy_payload = response.parsed_body.dig('payload', 'routing_policy')
    expect(policy_payload).to include(
      'mode' => 'ai',
      'ai_deployment_mode' => 'onelink_managed',
      'ai_app_ref' => 'local-ai-app',
      'onelink_ai_app_ref' => 'onelink-ai-voice-app',
      'effective_ai_app_ref' => 'onelink-ai-voice-app',
      'captain_assistant_id' => assistant.id
    )
    expect(policy_payload.dig('ai_voice_settings', 'language')).to eq('ru-KZ')
    expect(number_binding.reload.app_ref).to be_nil
  end

  it 'rejects a captain assistant from another account' do
    other_assistant = create(:captain_assistant)

    post update_path,
         params: {
           mode: 'ai',
           ai_app_ref: 'onelink-ai-voice-app',
           captain_assistant_id: other_assistant.id
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to include('Captain assistant must belong to the routing policy account')
  end
end
