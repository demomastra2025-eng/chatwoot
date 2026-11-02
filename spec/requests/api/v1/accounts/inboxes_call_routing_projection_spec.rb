require 'rails_helper'

RSpec.describe 'Inbox call routing public projection', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { { api_access_token: admin.access_token.token } }
  let(:public_routing) do
    { 'show_extended_call_card' => false,
      'inbound' => { 'schedule_mode' => 'business_hours', 'ring_timeout_seconds' => 47, 'skip_busy_operators' => false },
      'outbound' => { 'allowed_user_ids' => [7] } }
  end
  let(:raw_routing) do
    public_routing.deep_merge('show_extended_call_card' => 'false',
                              'inbound' => { 'ring_timeout_seconds' => '47', 'skip_busy_operators' => '0',
                                             'archive' => { 'system_prompt' => 'PRIVATE_WA_ROUTING_ARCHIVE' } },
                              'outbound' => { 'allowed_user_ids' => ['7'] })
  end
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
  end
  let(:path) { "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}" }
  let(:private_config) do
    channel.provider_config.merge('call_routing' => raw_routing, 'calling_enabled' => false, 'ai_voice_enabled' => false,
                                  'api_key' => 'PRIVATE_WA_TRANSPORT_SECRET', 'app_secret' => 'PRIVATE_WA_APP_SECRET',
                                  'webhook_verify_token' => 'PRIVATE_WA_WEBHOOK_SECRET')
  end

  it 'hides the Cloud routing sentinel from the whole GET/list body for administrators and agents' do
    channel.update!(provider_config: private_config)
    [admin, agent].each do |user|
      [path, "/api/v1/accounts/#{account.id}/inboxes"].each do |url|
        get url, headers: { api_access_token: user.access_token.token }, as: :json
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('PRIVATE_WA_ROUTING_ARCHIVE', 'PRIVATE_WA_TRANSPORT_SECRET', 'PRIVATE_WA_APP_SECRET',
                                             'PRIVATE_WA_WEBHOOK_SECRET')
        payload = url == path ? response.parsed_body : response.parsed_body['payload'].find { |inbox| inbox['id'] == channel.inbox.id }
        expect(payload['call_routing']).to eq(public_routing)
        expect(payload.fetch('provider_config', {})).not_to have_key('call_routing')
      end
    end
  end

  it 'preserves raw Cloud routing, AI flags and secrets exactly during unrelated transport GET to PATCH' do
    channel.update!(provider_config: private_config)
    saved = channel.reload.provider_config.deep_dup
    get path, headers: headers, as: :json
    public_config = response.parsed_body.fetch('provider_config')
    expect(public_config).not_to have_key('call_routing')
    expect(channel.reload.provider_config).to eq(saved)
    patch path, params: { channel: { provider_config: public_config.merge('calling_capable' => true) } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('PRIVATE_WA_ROUTING_ARCHIVE', 'PRIVATE_WA_TRANSPORT_SECRET', 'PRIVATE_WA_APP_SECRET',
                                         'PRIVATE_WA_WEBHOOK_SECRET')
    expect(channel.reload.provider_config).to eq(saved.merge('calling_capable' => true))
    expect(response.parsed_body['call_routing']).to eq(public_routing)
  end

  it 'accepts an ordinary Cloud business routing patch and returns the same typed field' do
    channel.update!(provider_config: private_config)
    changed_routing = public_routing.deep_merge('show_extended_call_card' => true, 'inbound' => { 'ring_timeout_seconds' => 55 })
    patch path, params: { channel: { provider_config: { call_routing: changed_routing } } }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['call_routing']).to eq(changed_routing)
    expect(response.parsed_body.fetch('provider_config')).not_to have_key('call_routing')
    expect(channel.reload.provider_config).to include('call_routing' => changed_routing, 'ai_voice_enabled' => false,
                                                      'api_key' => 'PRIVATE_WA_TRANSPORT_SECRET', 'app_secret' => 'PRIVATE_WA_APP_SECRET',
                                                      'webhook_verify_token' => 'PRIVATE_WA_WEBHOOK_SECRET')
  end

  context 'with WhatsApp Web' do
    let(:channel) do
      create(:channel_whatsapp_web, account: account,
                                    provider_config: { 'call_routing' => raw_routing, 'calling_enabled' => false,
                                                       'ai_voice_settings' => { 'system_prompt' => 'PRIVATE_WA_AI_PROMPT',
                                                                                'archive' => { 'prompt' => 'PRIVATE_WA_AI_ARCHIVE' } } })
    end

    it 'hides every raw routing alias and preserves private storage during a transport roundtrip' do
      saved = channel.provider_config.deep_dup
      get path, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('PRIVATE_WA_ROUTING_ARCHIVE', 'PRIVATE_WA_AI_PROMPT', 'PRIVATE_WA_AI_ARCHIVE')
      expect(response.parsed_body['call_routing']).to eq(public_routing)
      public_config = response.parsed_body.fetch('provider_config')
      expect(public_config).not_to have_key('call_routing')
      # WAWeb runtime/provider identity is immutable; its ordinary settings
      # update writes only the editable business field, never a raw config copy.
      patch path, params: { channel: { sign_messages: true } }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('PRIVATE_WA_ROUTING_ARCHIVE', 'PRIVATE_WA_AI_PROMPT', 'PRIVATE_WA_AI_ARCHIVE')
      expect(channel.reload).to have_attributes(sign_messages: true, provider_config: saved)
    end
  end
end
