require 'rails_helper'

RSpec.describe Telephony::VirtualPbx::RemotePlanBuilder do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:service) { Telephony::VirtualPbx::ProvisioningService.new(account: account, current_user: admin) }
  let(:base_payload) do
    {
      provider_kind: 'sipuni',
      channel_name: 'Sipuni external line',
      display_phone_number: '+17705550999',
      provider_account_number: '056124100014',
      ingress_number: '056124100014',
      connection: { host: 'ats01.kz.sipuni.com', port: 5060, transport: 'udp', username: '056124100014', password: 'do-not-return' }
    }
  end

  it 'builds a sanitized local-only create plan through the shared Sipuni gateway' do
    result = service.create_channel(base_payload, dry_run: false)
    state = Telephony::VirtualPbx::DesiredStateBuilder.new(account: account).for_inbox(result.dig(:ui_config, :inbox_id))

    plan = nil
    with_modified_env(TELEPHONY_BRIDGE_ONELINK_BASE_URL: 'https://dev.one-link.kz') do
      plan = described_class.new(account: account).build(operation: 'create', desired_state: state)
    end

    expect(plan).to include(status: 'dry_run_valid', remote_mutations: 'requires_approval')
    expect(plan.fetch(:operations).map { |operation| operation[:key] }).to include(
      'upsert_sipuni_gateway', 'upsert_number', 'update_number_route'
    )
    expect(plan.fetch(:operations).map { |operation| operation[:key] }).not_to include('upsert_trunk')
    gateway_operation = plan.fetch(:operations).find { |operation| operation[:key] == 'upsert_sipuni_gateway' }
    number_operation = plan.fetch(:operations).find { |operation| operation[:key] == 'upsert_number' }
    route_operation = plan.fetch(:operations).find { |operation| operation[:key] == 'update_number_route' }
    expect(gateway_operation).to include(method: 'PUT', path: '/telephony/sipuni-gateways/sipuni-internal-asterisk-056124100014')
    expect(gateway_operation.dig(:payload, :providerAccountNumber)).to eq('056124100014')
    expect(gateway_operation.dig(:payload, :credentialsRef)).to eq("cred-sipuni-acct-#{account.id}-056124100014")
    expect(gateway_operation.dig(:payload, :metadata, :onelink_base_url)).to eq('https://dev.one-link.kz')
    expect(number_operation.dig(:payload, :metadata, :onelink_base_url)).to eq('https://dev.one-link.kz')
    expect(route_operation.dig(:payload, :metadata, :onelink_base_url)).to eq('https://dev.one-link.kz')
    expect(plan.fetch(:operations)).to all(include(risk: 'requires_approval'))
    expect(plan.to_json).not_to include('do-not-return')
  end

  it 'does not plan the Sipuni Asterisk gateway before any shared or employee credentials exist' do
    payload = base_payload.deep_dup
    payload[:connection].delete(:username)
    payload[:connection].delete(:password)
    result = service.create_channel(payload, dry_run: false)
    state = Telephony::VirtualPbx::DesiredStateBuilder.new(account: account).for_inbox(result.dig(:ui_config, :inbox_id))

    plan = described_class.new(account: account).build(operation: 'create', desired_state: state)

    expect(plan.fetch(:operations).map { |operation| operation[:key] }).to include(
      'upsert_number', 'update_number_route'
    )
    expect(plan.fetch(:operations).map { |operation| operation[:key] }).not_to include(
      'upsert_connection_credentials',
      'upsert_sipuni_gateway'
    )
  end

  it 'builds Asterisk analog over the same shared internal trunk without creating per-line trunks' do
    payload = base_payload.deep_dup.merge(
      provider_kind: 'asterisk_analog',
      channel_name: 'Analog 9098',
      display_phone_number: '+77171235175',
      provider_account_number: 'tel:9098',
      ingress_number: 'tel:9098'
    )
    payload[:connection].delete(:username)
    payload[:connection].delete(:password)
    result = service.create_channel(payload, dry_run: false)
    state = Telephony::VirtualPbx::DesiredStateBuilder.new(account: account).for_inbox(result.dig(:ui_config, :inbox_id))

    plan = described_class.new(account: account).build(operation: 'create', desired_state: state)
    operation_keys = plan.fetch(:operations).map { |operation| operation[:key] }
    number_operation = plan.fetch(:operations).find { |operation| operation[:key] == 'upsert_number' }
    route_operation = plan.fetch(:operations).find { |operation| operation[:key] == 'update_number_route' }

    expect(state.dig(:refs, :number_ref)).to eq("asterisk-analog-#{account.id}-9098")
    expect(state.dig(:refs, :trunk_ref)).to eq('trunk-sipuni-onelink-out')
    expect(operation_keys).to include('upsert_number', 'update_number_route')
    expect(operation_keys).not_to include('upsert_trunk', 'upsert_sipuni_gateway')
    expect(number_operation.dig(:payload, :telUrl)).to eq('tel:9098')
    expect(number_operation.dig(:payload, :trunkRef)).to eq('trunk-sipuni-onelink-out')
    expect(number_operation.dig(:payload, :metadata, :provider_kind)).to eq('asterisk_analog')
    expect(route_operation.dig(:payload, :metadata, :provider_kind)).to eq('asterisk_analog')
    expect(route_operation.dig(:payload, :metadata, :ingress_number)).to eq('9098')
  end

  it 'uses idempotent upserts for updates so missing remote resources can be repaired' do
    result = service.create_channel(base_payload, dry_run: false)
    state = Telephony::VirtualPbx::DesiredStateBuilder.new(account: account).for_inbox(result.dig(:ui_config, :inbox_id))

    plan = described_class.new(account: account).build(operation: 'update', desired_state: state)

    expect(plan.fetch(:operations).map { |operation| [operation[:key], operation[:method]] }).to include(
      %w[upsert_sipuni_gateway PUT],
      %w[upsert_number PUT],
      %w[update_number_route POST]
    )
    expect(plan.fetch(:operations).map { |operation| operation[:key] }).not_to include(
      'upsert_trunk',
      'patch_trunk',
      'patch_number',
      'patch_number_route'
    )
  end

  it 'plans browser webphone employee SIP credentials without exposing raw passwords' do
    desired_state = {
      account_id: account.id,
      provider_kind: 'sipuni',
      name: 'Sipuni external line',
      refs: { number_ref: 'number-ref', trunk_ref: 'trunk-sipuni-onelink-out' },
      phone_numbers: { fonoster_tel_url: 'tel:+17705550999' },
      routing: { mode: 'operator' },
      ownership: {
        managed_by: 'onelink',
        ownership_status: 'local',
        onelink_account_id: account.id
      },
      profiles: [
        {
          user_id: admin.id,
          user_name: 'Admin',
          internal_extension: '504',
          agent_ref: 'profile-1-504',
          agent_aor: 'sip:504@operator.cloud.vconsult.kz',
          availability_mode: 'browser_webphone',
          credentials_ref: 'cred-profile-1-504',
          sip_username: '015856100014',
          sip_password: 'do-not-store-this-password',
          enabled: true
        }
      ]
    }

    plan = described_class.new(account: account).build(operation: 'update', desired_state: desired_state)
    operations = plan.fetch(:operations)
    operation_keys = operations.map { |operation| operation[:key] }
    credential_operation = operations.find { |operation| operation[:key] == 'upsert_agent_credentials' }
    gateway_operation = operations.find { |operation| operation[:key] == 'upsert_sipuni_gateway' }
    agent_operation = operations.find { |operation| operation[:key] == 'upsert_agent' }

    expect(operation_keys.index('upsert_agent_credentials')).to be < operation_keys.index('upsert_sipuni_gateway')
    expect(gateway_operation.dig(:payload, :providerAccountNumber)).to eq('015856100014')
    expect(gateway_operation.dig(:payload, :credentialsRef)).to eq('cred-profile-1-504')
    expect(gateway_operation.dig(:payload, :metadata, :target_extension)).to eq('504')
    expect(gateway_operation.dig(:payload, :metadata, :operator_agent_aor)).to eq('sip:504@operator.cloud.vconsult.kz')
    expect(gateway_operation.dig(:payload, :metadata, :onelink_user_id)).to eq(admin.id)
    expect(credential_operation).to include(
      method: 'PUT',
      path: '/telephony/credentials/cred-profile-1-504',
      risk: 'requires_approval'
    )
    expect(credential_operation.dig(:payload, :name)).to eq('Admin 504')
    expect(credential_operation.dig(:payload, :username)).to eq('015856100014')
    expect(credential_operation.dig(:payload, :password)).to eq('[REDACTED]')
    expect(agent_operation.dig(:payload, :credentialsRef)).to eq('cred-profile-1-504')
    expect(agent_operation.dig(:payload, :domain)).to eq('operator.cloud.vconsult.kz')
    expect(agent_operation.dig(:payload, :domainUri)).to eq('operator.cloud.vconsult.kz')
    expect(plan.to_json).not_to include('do-not-store-this-password')
  end

  it 'plans one Sipuni Asterisk gateway per browser webphone employee profile with target metadata' do
    desired_state = {
      account_id: account.id,
      provider_kind: 'sipuni',
      name: 'Sipuni external line',
      refs: { number_ref: 'sipuni-internal-asterisk-015856100014', trunk_ref: 'trunk-sipuni-onelink-out' },
      phone_numbers: { fonoster_tel_url: 'tel:+177****0999', ingress_number: '015856100014' },
      routing: { mode: 'operator', app_ref: 'onelink-runtime-app' },
      ownership: {
        managed_by: 'onelink',
        ownership_status: 'local',
        onelink_account_id: account.id,
        onelink_inbox_id: 158,
        onelink_channel_id: 777
      },
      profiles: [
        {
          id: 2,
          user_id: admin.id + 1,
          user_name: 'Second',
          internal_extension: '505',
          agent_ref: 'profile-1-505',
          agent_aor: 'sip:505@operator.cloud.vconsult.kz',
          availability_mode: 'browser_webphone',
          credentials_ref: 'cred-profile-1-505',
          sip_username: '015856100015',
          sip_password: 'do-not-store-this-password-505',
          enabled: true
        },
        {
          id: 1,
          user_id: admin.id,
          user_name: 'Admin',
          internal_extension: '504',
          agent_ref: 'profile-1-504',
          agent_aor: 'sip:504@operator.cloud.vconsult.kz',
          availability_mode: 'browser_webphone',
          credentials_ref: 'cred-profile-1-504',
          sip_username: '015856100014',
          sip_password: 'do-not-store-this-password-504',
          enabled: true
        }
      ]
    }

    plan = described_class.new(account: account).build(operation: 'update', desired_state: desired_state)
    gateway_operations = plan.fetch(:operations).select { |operation| operation[:key] == 'upsert_sipuni_gateway' }

    expect(gateway_operations.map { |operation| operation[:path] }).to eq(
      [
        '/telephony/sipuni-gateways/sipuni-internal-asterisk-015856100014',
        '/telephony/sipuni-gateways/sipuni-internal-asterisk-015856100014-505'
      ]
    )
    expect(gateway_operations.map { |operation| operation.dig(:payload, :numberRef) }).to eq(
      %w[sipuni-internal-asterisk-015856100014 sipuni-internal-asterisk-015856100014]
    )
    expect(gateway_operations.map { |operation| operation.dig(:payload, :providerAccountNumber) }).to eq(%w[015856100014 015856100015])
    expect(gateway_operations.map { |operation| operation.dig(:payload, :credentialsRef) }).to eq(%w[cred-profile-1-504 cred-profile-1-505])
    expect(gateway_operations.map { |operation| operation.dig(:payload, :metadata, :target_extension) }).to eq(%w[504 505])
    expect(gateway_operations.map { |operation| operation.dig(:payload, :metadata, :operator_agent_aor) }).to eq(
      ['sip:504@operator.cloud.vconsult.kz', 'sip:505@operator.cloud.vconsult.kz']
    )
    expect(plan.to_json).not_to include('do-not-store-this-password')
  end

  it 'skips Sipuni gateway upserts for existing employee profiles without usable remote credentials' do
    desired_state = {
      account_id: account.id,
      provider_kind: 'sipuni',
      name: 'Sipuni external line',
      refs: { number_ref: 'sipuni-internal-asterisk-015856100014', trunk_ref: 'trunk-sipuni-onelink-out' },
      phone_numbers: { fonoster_tel_url: 'tel:+177****0999', ingress_number: '015856100014' },
      routing: { mode: 'operator', app_ref: 'onelink-runtime-app' },
      ownership: {
        managed_by: 'onelink',
        ownership_status: 'local',
        onelink_account_id: account.id,
        onelink_inbox_id: 158,
        onelink_channel_id: 777
      },
      profiles: [
        {
          id: 2,
          user_id: admin.id + 1,
          user_name: 'Existing',
          internal_extension: '502',
          agent_ref: 'profile-1-502',
          agent_aor: 'sip:502@operator.cloud.vconsult.kz',
          availability_mode: 'browser_webphone',
          credentials_ref: 'cred-profile-1-502',
          sip_username: '015856100006',
          access_configured: true,
          enabled: true
        },
        {
          id: 3,
          user_id: admin.id + 2,
          user_name: 'New',
          internal_extension: '503',
          agent_ref: 'profile-1-503',
          agent_aor: 'sip:503@operator.cloud.vconsult.kz',
          availability_mode: 'browser_webphone',
          credentials_ref: 'cred-profile-1-503',
          sip_username: '015856100010',
          sip_password: 'do-not-store-this-password-503',
          enabled: true
        },
        {
          id: 1,
          user_id: admin.id,
          user_name: 'Existing Secondary',
          internal_extension: '504',
          agent_ref: 'profile-1-504',
          agent_aor: 'sip:504@operator.cloud.vconsult.kz',
          availability_mode: 'browser_webphone',
          credentials_ref: 'cred-profile-1-504',
          sip_username: '015856100014',
          access_configured: true,
          enabled: true
        }
      ]
    }

    plan = described_class.new(account: account).build(operation: 'update', desired_state: desired_state)
    gateway_operations = plan.fetch(:operations).select { |operation| operation[:key] == 'upsert_sipuni_gateway' }

    expect(gateway_operations.map { |operation| operation[:path] }).to eq(
      ['/telephony/sipuni-gateways/sipuni-internal-asterisk-015856100014-503']
    )
    expect(gateway_operations.first.dig(:payload, :providerAccountNumber)).to eq('015856100010')
    expect(gateway_operations.first.dig(:payload, :credentialsRef)).to eq('cred-profile-1-503')
    expect(gateway_operations.first.dig(:payload, :metadata, :target_extension)).to eq('503')
    expect(plan.to_json).not_to include('do-not-store-this-password')
  end

  it 'does not plan Routr agent CRUD for provider-managed Sipuni extensions' do
    desired_state = {
      account_id: account.id,
      provider_kind: 'sipuni',
      name: 'Sipuni external line',
      refs: { number_ref: 'number-ref', trunk_ref: 'trunk-sipuni-onelink-out' },
      phone_numbers: { fonoster_tel_url: 'tel:+17705550999' },
      routing: { mode: 'operator' },
      ownership: {
        managed_by: 'onelink',
        ownership_status: 'local',
        onelink_account_id: account.id
      },
      profiles: [
        {
          user_id: admin.id,
          user_name: 'Admin',
          internal_extension: '504',
          agent_ref: 'profile-1-504',
          agent_aor: 'sip:504@ats01.kz.sipuni.com',
          availability_mode: 'external_extension',
          credentials_ref: 'cred-profile-1-504',
          sip_username: '015856100014',
          sip_password: 'do-not-store-this-password',
          enabled: true
        }
      ]
    }

    plan = described_class.new(account: account).build(operation: 'update', desired_state: desired_state)

    expect(plan.fetch(:operations).map { |operation| operation[:key] }).to include(
      'upsert_number', 'update_number_route'
    )
    expect(plan.fetch(:operations).map { |operation| operation[:key] }).not_to include(
      'upsert_sipuni_gateway',
      'upsert_agent_credentials',
      'upsert_agent'
    )
    expect(plan.to_json).not_to include('do-not-store-this-password')
  end

  it 'plans employee SIP credential cleanup when deleting a managed inbox' do
    desired_state = {
      account_id: account.id,
      inbox_id: 1001,
      provider_kind: 'sipuni',
      refs: { number_ref: 'number-ref', trunk_ref: 'trunk-sipuni-onelink-out' },
      ownership: {
        managed_by: 'onelink',
        ownership_status: 'local',
        onelink_account_id: account.id
      },
      profiles: [
        {
          user_id: admin.id,
          internal_extension: '504',
          agent_ref: 'agent-ref',
          availability_mode: 'browser_webphone',
          credentials_ref: 'cred-profile-delete'
        }
      ]
    }

    plan = described_class.new(account: account).build(operation: 'delete', desired_state: desired_state)

    expect(plan.fetch(:operations).map { |operation| [operation[:key], operation[:method], operation[:path]] }).to include(
      ['delete_agent', 'DELETE', '/telephony/agents/agent-ref'],
      ['delete_agent_credentials', 'DELETE', '/telephony/credentials/cred-profile-delete'],
      ['delete_sipuni_gateway', 'DELETE', '/telephony/sipuni-gateways/number-ref'],
      ['delete_number', 'DELETE', '/telephony/numbers/number-ref']
    )
  end

  it 'plans cleanup for employee SIP profiles replaced through the OneLink UI' do
    desired_state = {
      account_id: account.id,
      inbox_id: 1001,
      provider_kind: 'sipuni',
      refs: { number_ref: 'number-ref', trunk_ref: 'trunk-sipuni-onelink-out' },
      ownership: {
        managed_by: 'onelink',
        ownership_status: 'local',
        onelink_account_id: account.id
      },
      profiles: [
        {
          user_id: admin.id,
          internal_extension: '5555',
          agent_ref: 'new-agent-ref',
          credentials_ref: 'new-credentials-ref',
          availability_mode: 'browser_webphone',
          sip_username: '015856100099',
          sip_password: 'new-password',
          enabled: true
        }
      ],
      stale_profiles: [
        {
          user_id: admin.id,
          internal_extension: '504',
          agent_ref: 'old-agent-ref',
          credentials_ref: 'old-credentials-ref',
          availability_mode: 'browser_webphone',
          sip_username: '015856100020',
          enabled: true
        }
      ]
    }

    plan = described_class.new(account: account).build(operation: 'update', desired_state: desired_state)
    operation_paths = plan.fetch(:operations).map { |operation| [operation[:key], operation[:method], operation[:path]] }

    expect(operation_paths).to include(
      ['delete_stale_agent', 'DELETE', '/telephony/agents/old-agent-ref'],
      ['delete_stale_agent_credentials', 'DELETE', '/telephony/credentials/old-credentials-ref'],
      ['delete_stale_sipuni_gateway', 'DELETE', '/telephony/sipuni-gateways/015856100020'],
      ['delete_stale_sipuni_gateway', 'DELETE', '/telephony/sipuni-gateways/number-ref-504'],
      ['upsert_agent_credentials', 'PUT', '/telephony/credentials/new-credentials-ref'],
      ['upsert_sipuni_gateway', 'PUT', '/telephony/sipuni-gateways/number-ref'],
      ['upsert_agent', 'PUT', '/telephony/agents/new-agent-ref']
    )
    stale_gateway_index = operation_paths.index(['delete_stale_sipuni_gateway', 'DELETE', '/telephony/sipuni-gateways/number-ref-504'])
    upsert_gateway_index = operation_paths.index(['upsert_sipuni_gateway', 'PUT', '/telephony/sipuni-gateways/number-ref'])
    expect(stale_gateway_index).to be < upsert_gateway_index
    expect(plan.to_json).not_to include('new-password')
  end

  it 'keeps shared non-Sipuni trunks when another inbox uses the same provider connection' do
    provider_connection = create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'asterisk_analog',
      credentials_ref: 'shared-provider-cred',
      fonoster_credentials_ref: 'shared-provider-cred',
      fonoster_trunk_ref: 'shared-trunk-ref'
    )
    other_inbox = create(:inbox, account: account)
    create(
      :telephony_number_binding,
      account: account,
      inbox: other_inbox,
      provider_connection: provider_connection,
      number_ref: 'other-number-ref',
      trunk_ref: 'shared-trunk-ref',
      managed_by: 'onelink',
      ownership_status: 'local'
    )
    desired_state = {
      account_id: account.id,
      inbox_id: 1001,
      provider_kind: 'asterisk_analog',
      refs: { number_ref: 'number-ref', trunk_ref: 'shared-trunk-ref', credentials_ref: 'shared-provider-cred' },
      resources: { provider_connection_id: provider_connection.id },
      ownership: {
        managed_by: 'onelink',
        ownership_status: 'local',
        onelink_account_id: account.id
      }
    }

    plan = described_class.new(account: account).build(operation: 'delete', desired_state: desired_state)

    expect(plan.fetch(:operations).map { |operation| operation[:key] }).to include('delete_number')
    expect(plan.fetch(:operations).map { |operation| operation[:key] }).not_to include('delete_trunk', 'delete_connection_credentials')
  end

  it 'does not delete Routr agents for provider-managed Sipuni extensions' do
    desired_state = {
      account_id: account.id,
      inbox_id: 1001,
      provider_kind: 'sipuni',
      refs: { number_ref: 'number-ref', trunk_ref: 'trunk-sipuni-onelink-out' },
      ownership: {
        managed_by: 'onelink',
        ownership_status: 'local',
        onelink_account_id: account.id
      },
      profiles: [
        {
          user_id: admin.id,
          internal_extension: '504',
          agent_ref: 'agent-ref',
          availability_mode: 'external_extension',
          credentials_ref: 'cred-profile-delete'
        }
      ]
    }

    plan = described_class.new(account: account).build(operation: 'delete', desired_state: desired_state)

    expect(plan.fetch(:operations).map { |operation| operation[:key] }).to include(
      'delete_sipuni_gateway',
      'delete_number'
    )
    expect(plan.fetch(:operations).map { |operation| operation[:key] }).not_to include('delete_agent')
  end

  it 'keeps employee SIP credentials that are still referenced by another inbox' do
    other_inbox = create(:inbox, account: account)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: other_inbox,
      credentials_ref: 'shared-credential-ref',
      fonoster_credentials_ref: 'shared-credential-ref'
    )
    desired_state = {
      account_id: account.id,
      inbox_id: 1001,
      provider_kind: 'sipuni',
      refs: { number_ref: 'number-ref', trunk_ref: 'trunk-sipuni-onelink-out' },
      ownership: {
        managed_by: 'onelink',
        ownership_status: 'local',
        onelink_account_id: account.id
      },
      profiles: [
        {
          user_id: admin.id,
          internal_extension: '504',
          agent_ref: 'agent-ref',
          credentials_ref: 'shared-credential-ref'
        }
      ]
    }

    plan = described_class.new(account: account).build(operation: 'delete', desired_state: desired_state)

    expect(plan.fetch(:operations).map { |operation| operation[:key] }).to include('delete_agent', 'delete_sipuni_gateway', 'delete_number')
    expect(plan.fetch(:operations).map { |operation| operation[:key] }).not_to include('delete_agent_credentials')
  end

  it 'blocks normal remote operations for legacy/unowned resources' do
    voice_channel = create(
      :channel_voice,
      :fonoster,
      account: account,
      phone_number: '+17705550123',
      provider_config: {
        number_ref: 'legacy-number',
        provider_kind: 'sipuni',
        display_phone_number: '+17705550123',
        ingress_number: '056124100014',
        operator_agent_aor: 'sip:100@operator.example.test'
      }
    )
    state = Telephony::VirtualPbx::DesiredStateBuilder.new(account: account).for_inbox(voice_channel.inbox.id)

    plan = described_class.new(account: account).build(operation: 'update', desired_state: state)

    expect(plan).to include(status: 'requires_manual_reconcile')
    expect(plan.fetch(:operations)).to all(include(risk: 'blocked'))
    expect(plan.fetch(:operations).first[:conflict]).to include('legacy')
  end
end
