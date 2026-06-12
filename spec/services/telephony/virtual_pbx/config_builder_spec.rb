require 'rails_helper'

RSpec.describe Telephony::VirtualPbx::ConfigBuilder do
  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, role: :agent) }

  def create_fonoster_channel(phone_number:, provider_config: {})
    create(
      :channel_voice,
      :fonoster,
      account: account,
      phone_number: phone_number,
      provider_config: {
        number_ref: 'fonoster-number-ref',
        app_ref: 'runtime-app-ref',
        trunk_ref: 'trunk-ref',
        routing_mode: 'operator',
        operator_agent_aor: Telephony::RoutingPolicy::CURRENT_FONOSTER_OPERATOR_AGENT_AOR
      }.merge(provider_config)
    )
  end

  it 'builds a split display/ingress bundle for legacy Asterisk analog resources' do
    voice_channel = create_fonoster_channel(
      phone_number: '+17715555175',
      provider_config: {
        provider_kind: 'asterisk_analog',
        display_phone_number: '+17715555175',
        ingress_number: '9098',
        fonoster_tel_url: 'tel:9098'
      }
    )
    binding = voice_channel.inbox.telephony_number_binding
    binding.update!(
      phone_number: '9098',
      metadata: {
        provider_kind: 'asterisk_analog',
        source: 'asterisk-analog',
        ingress_number: '9098',
        fonoster_tel_url: 'tel:9098'
      }
    )
    create(:telephony_agent_binding, :registered, account: account, user: operator,
                                                  agent_aor: Telephony::RoutingPolicy::CURRENT_FONOSTER_OPERATOR_AGENT_AOR)

    payload = described_class.new(account: account).for_inbox(voice_channel.inbox.id)

    expect(payload).to include(
      provider: 'fonoster',
      provider_kind: 'asterisk_analog',
      ready: true
    )
    expect(payload.fetch(:phone_numbers)).to include(
      display_phone_number: '+17715555175',
      ingress_number: '9098',
      fonoster_tel_url: 'tel:9098',
      split_allowed: true,
      legacy_channel_phone_differs_from_binding: true
    )
    expect(payload.dig(:ownership, :read_only)).to be(true)
    expect(payload.fetch(:warnings).map { |warning| warning[:code] }).to include('phone_split_configured', 'legacy_reference_resource')
  end

  it 'does not leak secret-like provider config or metadata values' do
    voice_channel = create_fonoster_channel(
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

  it 'exposes remote commit permission only when approval flag is enabled for managed local channels' do
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

    ui_config = builder.ui_config_for(inbox_id).with_indifferent_access
    expect(ui_config.dig(:permissions, :remote_commit_allowed)).to be(false)

    with_modified_env(TELEPHONY_VIRTUAL_PBX_REMOTE_COMMIT_ENABLED: 'true') do
      ui_config = builder.ui_config_for(inbox_id).with_indifferent_access

      expect(ui_config.dig(:permissions, :remote_commit_allowed)).to be(true)
      expect(ui_config.dig(:status, :remote_mutations)).to eq('requires_approval')
    end
  end
end
