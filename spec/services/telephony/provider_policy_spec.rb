require 'rails_helper'

RSpec.describe Telephony::ProviderPolicy do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:flag) { 'false' }

  around do |example|
    with_modified_env(
      'TELEPHONY_BEELINE_ENABLED' => flag,
      'TELEPHONY_BEELINE_JANUS_WS_URL' => 'wss://janus.example.test/janus-beeline',
      'TELEPHONY_JANUS_WS_URL' => 'wss://janus.example.test/janus-sipuni'
    ) { example.run }
  end

  def native_channel(provider)
    create(
      :channel_voice, :sipuni,
      account: account, provider: provider,
      provider_config: { provider_kind: provider, number_ref: SecureRandom.uuid, routing_mode: 'operator' }
    )
  end

  def browser_profile(channel)
    create(
      :telephony_sip_profile,
      account: account, inbox: channel.inbox, user: user,
      provider_connection: channel.inbox.telephony_number_binding.provider_connection,
      sip_host: 'sip.example.test', sip_username: SecureRandom.hex(8), sip_password: 'test-sip-secret',
      enabled: true, status: 'active', availability_mode: 'browser_webphone'
    )
  end

  def expect_disabled(&)
    expect(&).to raise_error(Telephony::Error) do |error|
      expect(error.code).to eq('TELEPHONY_PROVIDER_DISABLED')
      expect(error.status).to eq(:forbidden)
    end
  end

  it 'blocks bootstrap and explicit-inbox credentials without changing stored profiles or acquiring a lease' do
    channel = native_channel('beeline')
    profile = browser_profile(channel)
    original = profile.attributes.deep_dup
    service = Telephony::WebphoneService.new(account: account)

    [nil, channel.inbox].each do |inbox|
      payload = service.token_for(user: user, inbox: inbox, client_instance_id: 'policy-spec')
      expect(payload[:calling_supported]).to be(false)
      expect(payload).not_to have_key(:credentials)
      expect(payload).not_to have_key(:janus_server)
    end

    expect(profile.reload.attributes).to eq(original)
  end

  it 'keeps the next permitted provider available in bootstrap, resolver and no-inbox presence' do
    sipuni = browser_profile(native_channel('sipuni'))
    browser_profile(native_channel('beeline'))
    service = Telephony::WebphoneService.new(account: account)
    identity = Telephony::OperatorIdentityResolver.new(account: account, inbox: nil, user: user).resolve

    expect(identity.sip_profile.id).to eq(sipuni.id)
    expect(service.token_for(user: user, client_instance_id: 'policy-spec')[:sessions].pluck(:provider)).to eq(['sipuni'])
    expect(service.send(:ambiguous_no_inbox_sip_presence?, user, nil, identity)).to be(false)
  end

  it 'revokes an already-signed ticket and rejects minting even while the stored profile stays enabled' do
    profile = browser_profile(native_channel('beeline'))
    lease = profile.acquire_browser_registration_lease!(client_instance_id: 'policy-spec', user_id: user.id)
    arguments = {
      server_url: 'wss://janus.example.test/janus-beeline', account: account, user: user, sip_profile: profile,
      registration_instance_id: lease.fetch(:registration_instance_id)
    }
    ticket = nil
    with_modified_env('TELEPHONY_BEELINE_ENABLED' => 'true') do
      ticket = Telephony::JanusWebsocketTicket.issue(**arguments)
      expect(Telephony::JanusWebsocketTicket.valid?(ticket: ticket, origin: 'https://janus.example.test', path: '/janus-beeline')).to be(true)
    end

    expect(Redis::Alfred).not_to receive(:set)
    expect(Telephony::JanusWebsocketTicket.valid?(ticket: ticket, origin: 'https://janus.example.test', path: '/janus-beeline')).to be(false)
    expect(Telephony::JanusWebsocketTicket.authorize?(ticket: ticket, origin: 'https://janus.example.test', path: '/janus-beeline')).to be(false)
    expect_disabled { Telephony::JanusWebsocketTicket.issue(**arguments) }
    expect(profile.reload.enabled).to be(true)
  end

  it 'resolves a legacy Beeline profile through its channel even without a direct provider connection' do
    profile = browser_profile(native_channel('beeline'))
    profile.update!(provider_connection: nil)

    expect(described_class.enabled_for_profile?(profile)).to be(false)
  end

  it 'uses the legacy number binding when channel and direct provider connection are absent' do
    binding = instance_double(Telephony::NumberBinding, provider: 'beeline')
    inbox = instance_double(Inbox, channel: nil, telephony_number_binding: binding)
    profile = instance_double(Telephony::SipProfile, inbox: inbox, provider_connection: nil)

    expect(described_class.enabled_for_profile?(profile)).to be(false)
  end

  it 'excludes disabled AI profiles before serializing credentials or writing a registration version' do
    beeline = native_channel('beeline')
    blocked = create(
      :telephony_sip_profile, :voice_agent,
      account: account, inbox: beeline.inbox,
      provider_connection: nil, sip_host: 'sip.example.test', status: 'active'
    )
    blocked.update!(metadata: {})
    legacy_channel = native_channel('sipuni')
    legacy_channel.inbox.telephony_number_binding.update!(provider: 'beeline')
    legacy = create(
      :telephony_sip_profile, :voice_agent,
      account: account, inbox: legacy_channel.inbox,
      provider_connection: nil, sip_host: 'sip.example.test', status: 'active'
    )
    legacy.update!(metadata: {})
    sipuni = native_channel('sipuni')
    allowed = create(
      :telephony_sip_profile, :voice_agent,
      account: account, inbox: sipuni.inbox,
      provider_connection: sipuni.inbox.telephony_number_binding.provider_connection,
      sip_host: 'sip.example.test', status: 'active'
    )

    result = Telephony::AiVoice::JanusSipProfileConfigService.new.perform

    expect(result[:profiles].pluck(:id)).to contain_exactly(allowed.id)
    expect(blocked.reload.metadata).to eq({})
    expect(legacy.reload.metadata).to eq({})
  end

  it 'blocks new and existing native provisioning before it can create or re-enable resources' do
    beeline = native_channel('beeline')
    stored = browser_profile(beeline)
    sipuni = native_channel('sipuni')
    service = Telephony::VirtualPbx::ProvisioningService.new(account: account, current_user: user)
    initial = [Channel::Voice.count, Telephony::SipProfile.count]

    expect_disabled { service.create_channel({ provider_kind: 'beeline' }, dry_run: false) }
    expect_disabled { service.update_channel(inbox_id: beeline.inbox.id, payload: {}, dry_run: false) }
    expect_disabled { service.update_channel(inbox_id: sipuni.inbox.id, payload: { provider_kind: 'beeline' }, dry_run: false) }
    expect_disabled { service.provision(inbox_id: beeline.inbox.id) }
    expect_disabled { service.reconcile(inbox_id: beeline.inbox.id) }

    expect([Channel::Voice.count, Telephony::SipProfile.count]).to eq(initial)
    expect(stored.reload.enabled).to be(true)
    expect(Telephony::VirtualPbx::ConfigBuilder.provider_templates.keys).not_to include('beeline')
    expect(Telephony::VirtualPbx::ConfigBuilder.new(account: account).for_inbox(sipuni.inbox)[:provider_kind]).to eq('sipuni')
  end

  it 'does not advertise a preserved Beeline configuration as ready or supported' do
    channel = native_channel('beeline')
    browser_profile(channel)

    result = Telephony::ReadinessService.new(account: account).summary

    expect(result[:ready]).to be(false)
    expect(result[:inboxes]).to be_empty
    expect(result[:account]).to include(janus_sip_inboxes_count: 0, enabled_browser_sip_profiles_count: 0, number_bindings_count: 0)
    expect(result[:janus_sip][:providers]).not_to include('beeline')
    expect(Telephony::RoutingService.new(account: account).capabilities[:providers]).not_to include('beeline')
  end

  it 'blocks direct enable and incoming/outgoing entrypoints but permits local disabling' do
    channel = native_channel('beeline')
    profile = browser_profile(channel)
    agents = Telephony::AgentsService.new(account: account)
    expect_disabled { agents.set_enabled!(binding: profile, enabled: true) }
    expect(Telephony::OperatorBusyService).not_to receive(:new)
    expect_disabled do
      Telephony::CallsService.new(account: account).create_outbound!(inbox: channel.inbox, contact: nil, user: user, conversation: nil)
    end
    expect_disabled do
      Telephony::WebphoneService.new(account: account).report_browser_sip_incoming!(user: user, inbox: channel.inbox, params: {})
    end
    expect(agents.set_enabled!(binding: profile, enabled: false)['enabled']).to be(false)
  end

  it 'makes stored enabled profiles ineligible for routing without altering their stored flags' do
    profile = browser_profile(native_channel('beeline'))
    profile.update!(availability_mode: 'external_extension')
    with_modified_env('TELEPHONY_BEELINE_ENABLED' => nil) { expect(profile.registered_for_routing?).to be(true) }

    expect(profile.registered_for_routing?).to be(false)
    expect(profile.reload.enabled).to be(true)
  end

  it 'stops periodic polling before querying channels or acquiring Redis locks' do
    expect(Channel::Voice).not_to receive(:where)
    expect(Channel::Voice).not_to receive(:find_by)
    expect(Redis::LockManager).not_to receive(:new)
    expect(Telephony::BeelineCallHistorySyncJob).not_to receive(:perform_later)

    Telephony::BeelineCallHistorySyncJob.new.perform
    Telephony::BeelineCallHistorySyncJob.new.perform(channel_id: 123, subscribe_webhook: true)
  end

  it 'blocks subscription sync even with an injected configured client and explicit subscribe_webhook true' do
    channel = native_channel('beeline')
    before_config = channel.provider_config_hash.deep_dup
    client = instance_double(Telephony::Beeline::ApiClient)
    expect(client).not_to receive(:configured?)
    expect(client).not_to receive(:subscribe_webhook)
    expect(client).not_to receive(:statistics)

    result = Telephony::Beeline::CallHistorySyncService.new(channel: channel, api_client: client, subscribe_webhook: true).perform

    expect(result).to include(ok: true, reason: 'provider_disabled', synced: 0)
    expect(channel.reload.provider_config_hash).to eq(before_config)
  end

  it 'blocks recording downloads even with an injected client' do
    client = instance_double(Telephony::Beeline::ApiClient)
    expect(client).not_to receive(:configured?)
    expect(client).not_to receive(:download_recording)

    call_session = instance_double(Telephony::CallSession)
    service = Telephony::Beeline::RecordingSyncService.new(call_session: call_session, record_id: 'test-record', api_client: client)
    expect(service.perform).to be(false)
  end

  context 'when the flag is unset' do
    let(:flag) { nil }

    it 'preserves the existing Beeline browser contract and native configuration' do
      channel = native_channel('beeline')
      browser_profile(channel)
      result = Telephony::WebphoneService.new(account: account).token_for(user: user, inbox: channel.inbox, client_instance_id: 'policy-spec')

      expect(result).to include(provider: 'beeline', calling_supported: true)
      expect(result[:janus_server]).to include('/janus-beeline?', 'janus_ticket=')
      expect(Telephony::VirtualPbx::ConfigBuilder.provider_templates).to have_key('beeline')
    end

    it 'keeps Beeline AI profiles and provider API configuration enabled' do
      channel = native_channel('beeline')
      profile = create(
        :telephony_sip_profile, :voice_agent,
        account: account, inbox: channel.inbox,
        provider_connection: channel.inbox.telephony_number_binding.provider_connection,
        sip_host: 'sip.example.test', status: 'active'
      )

      expect(Telephony::AiVoice::JanusSipProfileConfigService.new.perform[:profiles].pluck(:id)).to include(profile.id)
      expect(Telephony::Beeline::ApiClient.new(api_token: 'test-api-token').configured?).to be(true)
    end
  end
end
