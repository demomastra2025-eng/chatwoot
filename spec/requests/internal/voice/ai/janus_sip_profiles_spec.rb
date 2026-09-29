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

  it 'keeps serving healthy profiles when one legacy profile or inbox cannot be serialized' do
    healthy = create(
      :telephony_sip_profile, :voice_agent,
      account: account, inbox: inbox, provider_connection: connection, internal_extension: '9098',
      sip_username: 'ai-agent-9098', sip_password: 'secret', sip_host: 'sip.example.test', status: 'active'
    )
    legacy_account = create(:account)
    legacy_inbox = create(:inbox, account: legacy_account)
    legacy = create(
      :telephony_sip_profile, :voice_agent,
      account: legacy_account, inbox: legacy_inbox, internal_extension: '9099',
      sip_username: 'ai-agent-9099', sip_password: 'secret', sip_host: 'sip.example.test', status: 'active'
    )
    # Legacy row that no longer passes validation and has no stored registration version yet.
    legacy.update_columns(user_id: create(:user).id, metadata: {}) # rubocop:disable Rails/SkipsModelValidations
    Channel::WebWidget.where(id: legacy_inbox.channel_id).delete_all
    allow(ChatwootExceptionTracker).to receive(:new).and_call_original

    with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
      get path, headers: { 'Authorization' => 'Bearer voice-secret' }
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['profiles'].pluck('id')).to eq([healthy.id])
    expect(ChatwootExceptionTracker).to have_received(:new)
      .with(having_attributes(class: ActiveRecord::RecordInvalid, record: legacy), account: legacy_account).once
  end

  context 'when a profile raises anything other than its own validation failure' do
    let!(:healthy) do
      create(
        :telephony_sip_profile, :voice_agent,
        account: account, inbox: inbox, provider_connection: connection, internal_extension: '9098',
        sip_username: 'ai-agent-9098', sip_password: 'secret', sip_host: 'sip.example.test', status: 'active'
      )
    end
    let!(:broken) do
      broken_account = create(:account)
      create(
        :telephony_sip_profile, :voice_agent,
        account: broken_account, inbox: create(:inbox, account: broken_account), internal_extension: '9099',
        sip_username: 'ai-agent-9099', sip_password: 'secret', sip_host: 'sip.example.test', status: 'active'
      )
    end

    # Any non-2xx answer without a profile list makes the sidecar keep its current sessions.
    {
      'a database timeout' => [-> { ActiveRecord::ConnectionTimeoutError.new('pool exhausted') }, :internal_server_error],
      'a code bug' => [-> { NoMethodError.new("undefined method 'registration' for nil") }, :internal_server_error],
      'a validation failure of another record' => [-> { ActiveRecord::RecordInvalid.new(Account.new) }, :unprocessable_content]
    }.each do |description, (build_error, expected_status)|
      it "fails the whole feed on #{description} so the sidecar keeps its registrations" do
        error = build_error.call
        broken_id = broken.id
        # rubocop:disable RSpec/AnyInstance
        allow_any_instance_of(Telephony::SipProfile).to receive(:ensure_registration_config_version!)
          .and_wrap_original do |original, *args|
            raise error if original.receiver.id == broken_id

            original.call(*args)
          end
        # rubocop:enable RSpec/AnyInstance
        allow(ChatwootExceptionTracker).to receive(:new).and_call_original

        with_modified_env(ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret') do
          get path, headers: { 'Authorization' => 'Bearer voice-secret' }
        end

        expect(response).to have_http_status(expected_status)
        expect(response.body).not_to include('"profiles"', healthy.sip_username)
        expect(ChatwootExceptionTracker).not_to have_received(:new)
      end
    end
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
