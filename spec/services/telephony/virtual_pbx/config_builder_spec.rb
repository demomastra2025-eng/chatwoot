require 'rails_helper'

RSpec.describe Telephony::VirtualPbx::ConfigBuilder do
  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, role: :agent) }
  let(:operator_agent_aor) { 'sip:9098@10.66.66.2' }

  def create_native_sip_channel(phone_number:, provider: 'sipuni', provider_config: {})
    create(
      :channel_voice,
      :sipuni,
      account: account,
      phone_number: phone_number,
      provider: provider,
      provider_config: {
        number_ref: 'fonoster-number-ref',
        app_ref: 'runtime-app-ref',
        trunk_ref: 'trunk-ref',
        routing_mode: 'operator',
        operator_agent_aor: operator_agent_aor
      }.merge(provider_config)
    )
  end

  it 'returns handled-call visibility without a number binding or routing policy' do
    voice_channel = create_native_sip_channel(
      phone_number: '+17775550124',
      provider_config: { show_calls_handled_by_other_operators: true }
    )
    voice_channel.inbox.telephony_number_binding&.destroy!

    payload = described_class.new(account: account).for_inbox(voice_channel.inbox)

    expect(payload.dig(:routing, :show_calls_handled_by_other_operators)).to be(true)
  end

  it 'builds a split display/ingress bundle for legacy Asterisk analog resources' do
    voice_channel = create_native_sip_channel(
      phone_number: '+17715555175',
      provider: 'asterisk_analog',
      provider_config: {
        provider_kind: 'asterisk_analog',
        display_phone_number: '+17715555175',
        ingress_number: '9098'
      }
    )
    binding = voice_channel.inbox.telephony_number_binding
    binding.update!(
      phone_number: '9098',
      metadata: {
        provider_kind: 'asterisk_analog',
        source: 'asterisk-analog',
        ingress_number: '9098'
      }
    )
    create(:telephony_agent_binding, :registered, account: account, user: operator,
                                                  agent_aor: operator_agent_aor)

    payload = described_class.new(account: account).for_inbox(voice_channel.inbox.id)

    expect(payload).to include(
      provider: 'asterisk_analog',
      provider_kind: 'asterisk_analog',
      ready: true
    )
    expect(payload.fetch(:phone_numbers)).to include(
      display_phone_number: '+17715555175',
      ingress_number: '9098',
      split_allowed: true,
      legacy_channel_phone_differs_from_binding: true
    )
    expect(payload.dig(:ownership, :read_only)).to be(true)
    expect(payload.fetch(:warnings).map { |warning| warning[:code] }).to include('phone_split_configured', 'legacy_reference_resource')
  end

  it 'does not leak secret-like provider config or metadata values' do
    voice_channel = create_native_sip_channel(
      phone_number: '+17715550123',
      provider_config: {
        provider_kind: 'sipuni',
        display_phone_number: '+17715550123',
        ingress_number: '056124100014',
        sip_password: 'super-secret-provider-password',
        api_token: 'provider-token'
      }
    )
    voice_channel.inbox.telephony_number_binding.update!(
      phone_number: '056124100014',
      metadata: {
        provider_kind: 'sipuni',
        webhook_secret: 'metadata-secret'
      }
    )

    payload = described_class.new(account: account).for_inbox(voice_channel.inbox)
    serialized = payload.to_json

    expect(serialized).not_to include('super-secret-provider-password')
    expect(serialized).not_to include('provider-token')
    expect(serialized).not_to include('metadata-secret')
    expect(payload.dig(:provider_config, 'sip_password')).to eq('[REDACTED]')
    expect(payload.dig(:metadata, 'webhook_secret')).to eq('[REDACTED]')
  end

  it 'keeps remote commit disabled for managed local channels without an env approval flag' do
    result = Telephony::VirtualPbx::ProvisioningService.new(account: account, current_user: operator).create_channel(
      {
        provider_kind: 'sipuni',
        channel_name: 'Sipuni managed line',
        display_phone_number: '+17715554444',
        provider_account_number: '056124100014',
        ingress_number: '056124100014',
        connection: { host: 'ats01.kz.sipuni.com', port: 5060, transport: 'udp', username: '056124100014' }
      },
      dry_run: false
    )
    builder = described_class.new(account: account)
    inbox_id = result.dig(:ui_config, :inbox_id)

    with_modified_env(TELEPHONY_VIRTUAL_PBX_REMOTE_COMMIT_ENABLED: nil) do
      ui_config = builder.ui_config_for(inbox_id).with_indifferent_access

      expect(ui_config.dig(:permissions, :remote_commit_allowed)).to be(false)
      expect(ui_config.dig(:status, :remote_mutations)).to eq('disabled')
    end
  end

  it 'marks managed Sipuni channels that request registration without SIP device credentials as not ready' do
    result = Telephony::VirtualPbx::ProvisioningService.new(account: account, current_user: operator).create_channel(
      {
        provider_kind: 'sipuni',
        channel_name: 'Sipuni managed line without trunk credentials',
        display_phone_number: '+17770004445',
        provider_account_number: '056124100015',
        ingress_number: '056124100015',
        connection: { host: 'ats01.kz.sipuni.com', port: 5060, transport: 'udp', username: '056124100015' }
      },
      dry_run: false
    )

    payload = described_class.new(account: account).for_inbox(result.dig(:ui_config, :inbox_id))

    expect(payload[:ready]).to be(false)
    expect(payload.fetch(:warnings).map { |warning| warning[:code] }).to include('missing_provider_sip_device_credentials')
  end

  it 'allows managed Sipuni channels to use the provider SIP device login even when it matches an employee SIP profile' do
    service = Telephony::VirtualPbx::ProvisioningService.new(account: account, current_user: operator)
    result = service.create_channel(
      {
        provider_kind: 'sipuni',
        channel_name: 'Sipuni managed line with employee trunk login',
        display_phone_number: '+15551234446',
        provider_account_number: 'shared-line-4446',
        ingress_number: 'shared-line-4446',
        connection: {
          host: 'ats01.kz.sipuni.com',
          port: 5060,
          transport: 'udp',
          username: 'manager-501-login',
          password: 'do-not-return-this-secret'
        }
      },
      dry_run: false
    )
    inbox = account.inboxes.find(result.dig(:ui_config, :inbox_id))
    binding = inbox.telephony_number_binding
    create(
      :telephony_sip_profile,
      account: account,
      inbox: inbox,
      user: operator,
      provider_connection: binding.provider_connection,
      internal_extension: '501',
      sip_username: 'manager-501-login',
      password_secret_ref: 'cred-profile-501',
      credentials_ref: 'cred-profile-501',
      availability_mode: 'browser_webphone',
      status: 'active'
    )

    payload = described_class.new(account: account).for_inbox(inbox.id)

    expect(payload[:ready]).to be(true)
    expect(payload.fetch(:warnings).map { |warning| warning[:code] }).not_to include(
      'shared_sipuni_trunk_uses_employee_profile',
      'missing_shared_sipuni_trunk_credentials',
      'missing_provider_sip_device_credentials'
    )
    expect(payload.to_json).not_to include('do-not-return-this-secret')
  end

  it 'builds managed Binotel channels without native SIP bridge resources' do
    result = Telephony::VirtualPbx::ProvisioningService.new(account: account, current_user: operator).create_channel(
      {
        provider_kind: 'binotel',
        channel_name: 'Binotel managed line',
        display_phone_number: '+77000781755',
        provider_account_number: '+77000781755',
        ingress_number: '+77000781755',
        connection: { host: 'sip53.binotel.com' },
        profiles: [
          {
            user_id: operator.id,
            internal_extension: '901',
            sip_username: 'pq4dyw5f',
            sip_password: 'do-not-return-binotel-secret',
            enabled: true
          }
        ]
      },
      dry_run: false
    )

    payload = described_class.new(account: account).for_inbox(result.dig(:ui_config, :inbox_id))

    expect(payload).to include(
      provider: 'binotel',
      provider_kind: 'binotel',
      ready: true
    )
    expect(payload.fetch(:phone_numbers)).not_to have_key(:fonoster_tel_url)
    expect(payload.dig(:resources, :app_ref)).to be_nil
    expect(payload.dig(:resources, :runtime_app_ref)).to be_nil
    expect(payload.dig(:resources, :trunk_ref)).to be_nil
    expect(payload.dig(:routing, :effective_app_ref)).to be_nil
    expect(payload.dig(:profiles, 0, 'availability_mode')).to eq('browser_webphone')
    expect(payload.to_json).not_to include('do-not-return-binotel-secret')
  end

  it 'does not invalidate settings version for browser presence lease heartbeats' do
    voice_channel = create_native_sip_channel(
      phone_number: "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}"
    )
    profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_channel.inbox,
      user: operator,
      internal_extension: '4141',
      availability_mode: 'browser_webphone'
    )
    builder = described_class.new(account: account)
    initial_version = builder.for_inbox(voice_channel.inbox.id).fetch(:configuration_version)

    profile.acquire_browser_registration_lease!(client_instance_id: 'tab-owner', user_id: operator.id)
    profile.ensure_registration_config_version!

    expect(builder.for_inbox(voice_channel.inbox.id).fetch(:configuration_version)).to eq(initial_version)

    profile.update!(internal_extension: '4142')
    expect(builder.for_inbox(voice_channel.inbox.id).fetch(:configuration_version)).not_to eq(initial_version)
  end

  it 'exposes non-secret Asterisk analog connection details for settings edits' do
    service = Telephony::VirtualPbx::ProvisioningService.new(account: account, current_user: operator)
    result = service.create_channel(
      {
        provider_kind: 'asterisk_analog',
        channel_name: 'Analog managed line',
        display_phone_number: '+17770004545',
        provider_account_number: 'analog-4545',
        ingress_number: 'analog-4545',
        connection: { host: '10.77.0.5', port: 5070, transport: 'tcp' }
      },
      dry_run: false
    )
    ui_config = described_class
                .new(account: account)
                .ui_config_for(result.dig(:ui_config, :inbox_id))
                .with_indifferent_access

    expect(ui_config.dig(:connection, :host)).to eq('10.77.0.5')
    expect(ui_config.dig(:connection, :port)).to eq(5070)
    expect(ui_config.dig(:connection, :transport)).to eq('tcp')
    expect(ui_config.to_json).not_to include('password')
  end
end
