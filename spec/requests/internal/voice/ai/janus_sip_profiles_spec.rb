require 'rails_helper'

RSpec.describe 'Internal Voice AI Janus SIP profiles', type: :request do
  let(:path) { '/internal/voice/ai/janus-sip/profiles' }
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:connection) do
    create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'sipuni',
      host: 'sip.example.test',
      port: 5070,
      transport: 'tcp'
    )
  end

  before do
    create(
      :telephony_number_binding,
      account: account,
      inbox: inbox,
      provider: 'sipuni',
      number_ref: 'sipuni-main',
      phone_number: '+77001234567',
      ingress_number: '+77007654321',
      provider_connection: connection
    )
  end

  it 'returns active voice-agent SIP profiles from inbox configuration' do
    create(
      :telephony_routing_policy,
      account: account,
      number_binding: inbox.telephony_number_binding,
      mode: 'ai',
      ai_app_ref: 'onelink-ai-runtime',
      fallback_mode: 'operator'
    )
    profile = create(
      :telephony_sip_profile,
      :voice_agent,
      account: account,
      inbox: inbox,
      provider_connection: connection,
      internal_extension: '9098',
      sip_username: 'ai-agent-9098',
      sip_password: 'secret',
      sip_host: 'sip.example.test',
      status: 'active'
    )
    create(:telephony_sip_profile, account: account, inbox: inbox, provider_connection: connection, status: 'active')
    create(:telephony_sip_profile, :voice_agent, account: account, enabled: false, status: 'active')

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get path, headers: { 'Authorization' => 'Bearer voice-secret' }
    end

    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(response.parsed_body['profiles'].size).to eq(1)
    expect(response.parsed_body['version']).to be_present
    expect(response.parsed_body['profiles'].first).to include(
      'id' => profile.id,
      'account_id' => account.id,
      'inbox_id' => inbox.id,
      'number_ref' => 'sipuni-main',
      'provider' => 'sipuni',
      'internal_extension' => '9098',
      'sip_username' => 'ai-agent-9098',
      'sip_password' => 'secret',
      'sip_host' => 'sip.example.test',
      'sip_port' => 5070,
      'sip_transport' => 'tcp',
      'app_ref' => 'onelink-ai-runtime',
      'routing_mode' => 'ai',
      'fallback_mode' => 'operator'
    )
    expect(response.parsed_body['profiles'].first['sip_profile']).to include(
      'id' => profile.id,
      'profile_kind' => 'voice_agent',
      'voice_agent' => true
    )
  end

  it 'requires internal voice authentication' do
    get path

    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns voice-agent SIP profiles for every native SIP provider' do
    providers = {
      'sipuni' => 'sip.sipuni.example',
      'binotel' => 'sip.binotel.example',
      'asterisk_analog' => 'asterisk.local'
    }

    providers.each_with_index do |(provider, host), index|
      provider_account = create(:account)
      provider_inbox = create(:inbox, account: provider_account)
      provider_connection = create(
        :telephony_provider_connection,
        account: provider_account,
        provider_kind: provider,
        host: host,
        port: 5060 + index,
        transport: index == 2 ? 'tcp' : 'udp'
      )
      create(
        :telephony_number_binding,
        account: provider_account,
        inbox: provider_inbox,
        provider: provider,
        number_ref: "#{provider}-number",
        provider_connection: provider_connection
      )
      create(
        :telephony_sip_profile,
        :voice_agent,
        account: provider_account,
        inbox: provider_inbox,
        provider_connection: provider_connection,
        internal_extension: "90#{index}",
        sip_username: "#{provider}-ai-agent",
        sip_password: 'secret',
        sip_host: host,
        status: 'active'
      )
    end

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get path, headers: { 'Authorization' => 'Bearer voice-secret' }
    end

    profiles = response.parsed_body['profiles'].index_by { |profile| profile['provider'] }
    expect(profiles.keys).to include('sipuni', 'binotel', 'asterisk_analog')
    expect(profiles['sipuni']).to include('sip_host' => 'sip.sipuni.example', 'sip_transport' => 'udp')
    expect(profiles['binotel']).to include('sip_host' => 'sip.binotel.example', 'sip_transport' => 'udp')
    expect(profiles['asterisk_analog']).to include('sip_host' => 'asterisk.local', 'sip_transport' => 'tcp')
  end
end
