require 'rails_helper'

RSpec.describe 'Telephony Virtual PBX channels API', type: :request do
  let(:account) { create(:account) }
  let(:valid_create_payload) do
    {
      provider_kind: 'sipuni',
      channel_name: 'Sipuni external line',
      display_phone_number: '+17715550999',
      provider_account_number: '056124100014',
      ingress_number: '056124100014',
      connection: {
        host: 'ats01.kz.sipuni.com',
        port: 5060,
        transport: 'udp',
        username: '056124100014',
        password: 'do-not-return-this-secret'
      }
    }
  end
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { administrator.create_new_auth_token }
  let(:base_path) { "/api/v1/accounts/#{account.id}/telephony/virtual_pbx_channels" }

  before do
    account.enable_features!('channel_voice')
  end

  it 'returns provider templates for the virtual PBX form defaults' do
    get "#{base_path}/templates", headers: headers

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'templates', 'remote_commit' => false, 'mutation_allowed' => false)
    expect(payload.dig('provider_templates', 'sipuni')).to include(
      'label' => 'Sipuni',
      'default_port' => 5060,
      'default_transport' => 'udp',
      'allows_display_ingress_split' => true
    )
  end

  def create_reference_channel
    voice_channel = create(
      :channel_voice,
      :fonoster,
      account: account,
      phone_number: '+17715550123',
      provider_config: {
        number_ref: 'sipuni-internal-asterisk-056124100014',
        app_ref: 'runtime-app-ref',
        trunk_ref: 'trunk-sipuni-onelink-out',
        provider_kind: 'sipuni',
        display_phone_number: '+17715550123',
        ingress_number: '056124100014',
        fonoster_tel_url: 'tel:056124100014',
        routing_mode: 'operator',
        operator_agent_aor: Telephony::RoutingPolicy::CURRENT_FONOSTER_OPERATOR_AGENT_AOR
      }
    )
    voice_channel.inbox.telephony_number_binding.update!(
      phone_number: '056124100014',
      metadata: {
        provider_kind: 'sipuni',
        ingress_number: '056124100014',
        fonoster_tel_url: 'tel:056124100014'
      }
    )
    voice_channel
  end

  def local_record_counts
    {
      voice_channels: Channel::Voice.count,
      inboxes: Inbox.count,
      number_bindings: Telephony::NumberBinding.count,
      routing_policies: Telephony::RoutingPolicy.count,
      agent_bindings: Telephony::AgentBinding.count,
      provider_connections: Telephony::ProviderConnection.count,
      sip_profiles: Telephony::SipProfile.count
    }
  end

  def create_payload_variant(display_phone_number:, provider_account_number:, ingress_number:, source: nil)
    valid_create_payload.deep_dup.tap do |payload|
      payload[:display_phone_number] = display_phone_number
      payload[:provider_account_number] = provider_account_number
      payload[:ingress_number] = ingress_number
      payload[:connection][:username] = provider_account_number
      payload[:metadata] = { source: source } if source.present?
    end
  end

  it 'returns a read-only unified config for a legacy/reference channel' do
    voice_channel = create_reference_channel

    get "#{base_path}/#{voice_channel.inbox.id}", headers: headers

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    ui_config = payload.fetch('ui_config')
    expect(payload).to include('operation' => 'show', 'mutation_allowed' => false)
    expect(ui_config.dig('channel', 'provider_kind')).to eq('sipuni')
    expect(ui_config.dig('status', 'ready')).to be(true)
    expect(ui_config.dig('channel', 'display_phone_number')).to be_present
    expect(ui_config.dig('status', 'read_only')).to be(true)
  end

  it 'maps legacy Sipuni account and ingress keys into split phone parts' do
    voice_channel = create(
      :channel_voice,
      :fonoster,
      account: account,
      phone_number: '+17705550124',
      provider_config: {
        number_ref: 'sipuni-internal-asterisk-056124100014',
        app_ref: 'runtime-app-ref',
        provider_kind: 'sipuni',
        display_phone_number: '+17705550124',
        sipuni_account_number: '056124100014',
        sipuni_ingress_number: '056124100014',
        fonoster_tel_url: 'tel:056124100014',
        routing_mode: 'operator',
        operator_agent_aor: Telephony::RoutingPolicy::CURRENT_FONOSTER_OPERATOR_AGENT_AOR
      }
    )
    voice_channel.inbox.telephony_number_binding.update!(
      phone_number: '056124100014',
      metadata: {
        source: 'sipuni_internal_asterisk_gateway',
        display_phone_number: '+17705550124',
        sipuni_account_number: '056124100014',
        sipuni_ingress_number: '056124100014'
      }
    )

    get "#{base_path}/#{voice_channel.inbox.id}", params: { include_diagnostics: true }, headers: headers

    expect(response).to have_http_status(:ok)
    phone_numbers = response.parsed_body.dig('payload', 'diagnostics', 'config', 'phone_numbers')
    expect(phone_numbers).to include(
      'display_phone_number' => '+17705550124',
      'provider_account_number' => '056124100014',
      'ingress_number' => '056124100014',
      'fonoster_tel_url' => 'tel:056124100014',
      'split_allowed' => true
    )
  end

  it 'accepts Sipuni account and ingress aliases during create dry-run' do
    payload = valid_create_payload.deep_dup
    payload[:sipuni_account_number] = payload.delete(:provider_account_number)
    payload[:sipuni_ingress_number] = payload.delete(:ingress_number)

    post base_path, params: payload.merge(include_diagnostics: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('operation' => 'create', 'dry_run' => true, 'valid' => true)
    expect(body.dig('diagnostics', 'payload', 'provider_account_number')).to eq('056124100014')
    expect(body.dig('diagnostics', 'payload', 'ingress_number')).to eq('056124100014')
    expect(body.dig('diagnostics', 'generated_refs', 'number_ref')).to eq('sipuni-internal-asterisk-056124100014')
  end

  it 'keeps Asterisk analog employee extensions out of channel provider numbers and remote agent upserts' do
    payload = valid_create_payload.deep_dup.merge(
      provider_kind: 'asterisk_analog',
      channel_name: 'Analog external line',
      display_phone_number: '+17770005175',
      provider_account_number: '+17770005175',
      ingress_number: '+17770005175',
      connection: {
        host: '10.77.0.5',
        port: 5060,
        transport: 'udp'
      },
      profiles: [
        {
          user_id: agent.id,
          internal_extension: '9098',
          enabled: true
        }
      ]
    )

    post base_path, params: payload.merge(include_diagnostics: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('operation' => 'create', 'dry_run' => true, 'valid' => true)
    expect(body.dig('diagnostics', 'payload', 'provider_account_number')).to eq('+17770005175')
    expect(body.dig('diagnostics', 'payload', 'ingress_number')).to eq('+17770005175')
    expect(body.dig('diagnostics', 'payload', 'fonoster_tel_url')).to eq('tel:+17770005175')
    expect(body.dig('diagnostics', 'payload', 'profiles').first).to include(
      'internal_extension' => '9098',
      'user_id' => agent.id,
      'availability_mode' => 'external_extension'
    )
    expect(body.dig('diagnostics', 'payload', 'connection', 'host')).to eq('10.77.0.5')
    expect(body.dig('diagnostics', 'payload', 'connection', 'send_register')).to be(false)
    expect(body.dig('diagnostics', 'generated_refs', 'number_ref')).to eq("asterisk-analog-#{account.id}-17770005175")
    expect(body.dig('diagnostics', 'generated_refs', 'trunk_ref')).to eq("trunk-asterisk-analog-acct-#{account.id}-17770005175")
    expect(body.dig('diagnostics', 'bridge_operations').map { |operation| operation['code'] }).to include(
      'upsert_trunk', 'upsert_number', 'update_number_route'
    )
    expect(body.dig('diagnostics', 'bridge_operations').map { |operation| operation['code'] }).not_to include(
      'upsert_agent', 'upsert_agent_credentials'
    )
    expect(body.to_json).not_to include('tel:9098')
  end

  it 'builds a create dry-run without changing local records or calling the bridge' do
    counts_before = local_record_counts

    post base_path, params: valid_create_payload.merge(include_diagnostics: true), headers: headers, as: :json

    expect(local_record_counts).to eq(counts_before)

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include(
      'operation' => 'create',
      'dry_run' => true,
      'valid' => true,
      'remote_commit' => false,
      'mutation_allowed' => false,
      'mutation_reason' => 'phase1_read_only_dry_run',
      'remote_mutation_allowed' => false,
      'remote_mutation_reason' => 'REMOTE_MUTATION_REQUIRES_APPROVAL',
      'status' => 'dry_run_ready'
    )
    expect(payload.dig('diagnostics', 'provider_template', 'label')).to eq('Sipuni')
    expect(payload.dig('diagnostics', 'bridge_operations').map { |operation| operation['method'] }).to include('PUT', 'POST')
    expect(payload.dig('diagnostics', 'bridge_operations')).to all(include('blocked' => true))
    expect(payload.dig('diagnostics', 'generated_refs', 'number_ref')).to eq('sipuni-internal-asterisk-056124100014')
    expect(payload.to_json).not_to include('do-not-return-this-secret')
    expect(payload.dig('diagnostics', 'payload', 'connection', 'password')).to eq('[REDACTED]')
  end

  it 'accepts simple create dry-run without employee SIP profiles' do
    post base_path, params: valid_create_payload.merge(include_diagnostics: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('operation' => 'create', 'dry_run' => true, 'valid' => true)
    expect(body.dig('diagnostics', 'payload', 'connection', 'username')).to eq('056124100014')
    expect(body.dig('diagnostics', 'payload', 'connection', 'password')).to eq('[REDACTED]')
    expect(body.dig('diagnostics', 'payload', 'profiles')).to eq([])
    expect(body.fetch('errors')).to eq([])
  end

  it 'defaults Sipuni employee SIP profiles to provider-managed extensions without browser-agent provisioning' do
    payload = valid_create_payload.deep_dup.merge(
      routing: { operator_distribution_mode: 'broadcast' },
      profiles: [
        {
          user_id: agent.id,
          internal_extension: '501',
          sip_username: 'sipuni-manager-501',
          sip_password: 'do-not-return-manager-secret',
          enabled: true
        }
      ]
    )

    post base_path, params: payload.merge(include_diagnostics: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('operation' => 'create', 'dry_run' => true, 'valid' => true)
    expect(body.dig('diagnostics', 'payload', 'profiles').first).to include(
      'internal_extension' => '501',
      'user_id' => agent.id,
      'availability_mode' => 'external_extension'
    )
    operation_codes = body.dig('diagnostics', 'bridge_operations').map { |operation| operation['code'] }
    expect(operation_codes).to include('upsert_number', 'update_number_route')
    expect(operation_codes).not_to include('upsert_agent', 'upsert_agent_credentials')
    expect(body.to_json).not_to include('do-not-return-manager-secret')
  end

  it 'accepts local-only create dry-run without shared provider password' do
    payload = valid_create_payload.deep_dup
    payload[:connection].delete(:username)
    payload[:connection].delete(:password)

    post base_path, params: payload.merge(include_diagnostics: true, remote_commit: false), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('operation' => 'create', 'dry_run' => true, 'valid' => true)
    expect(body.dig('diagnostics', 'payload', 'connection', 'username')).to be_nil
    expect(body.dig('diagnostics', 'payload', 'connection')).not_to include('password')
    expect(body.dig('diagnostics', 'payload', 'profiles')).to eq([])
  end

  it 'blocks remote create without shared Sipuni credentials before local records are committed' do
    payload = valid_create_payload.deep_dup
    payload[:connection].delete(:username)
    payload[:connection].delete(:password)
    counts_before = local_record_counts
    bridge_client = instance_double(Telephony::BridgeClient)
    allow(Telephony::BridgeClient).to receive(:new).and_return(bridge_client)
    allow(bridge_client).to receive(:get).with('/telephony/trunks/trunk-sipuni-onelink-out').and_return({})
    allow(bridge_client).to receive(:get).with('/telephony/trunks').and_return({ 'items' => [] })

    post base_path, params: payload.merge(dry_run: false, remote_commit: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include(
      'operation' => 'create',
      'dry_run' => false,
      'valid' => false,
      'status' => 'blocked',
      'local_commit' => false,
      'remote_commit' => false,
      'mutation_reason' => 'remote_plan_blocked_before_local_commit'
    )
    expect(body.fetch('errors').map { |error| error['code'] }).to include('missing_sipuni_gateway_credentials')
    expect(body.dig('provisioning_plan', 'operations').map { |operation| operation['key'] }).to include('missing_sipuni_gateway_credentials')
    expect(local_record_counts).to eq(counts_before)
  end

  it 'rejects explicitly supplied invalid SIP profile rows during create dry-run' do
    other_account = create(:account)
    outsider = create(:user, account: other_account, role: :agent)
    payload = valid_create_payload.deep_dup.merge(
      profiles: [
        {
          user_id: outsider.id,
          internal_extension: '207',
          sip_username: '056124100014',
          sip_password: 'do-not-return-this-profile-secret',
          enabled: true
        }
      ]
    )

    post base_path, params: payload, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('operation' => 'create', 'dry_run' => true, 'valid' => false)
    expect(body.fetch('errors').map { |error| error['code'] }).to include('profile_user_not_in_account')
    expect(body.to_json).not_to include('do-not-return-this-profile-secret')
  end

  it 'keeps remote mutation disabled only when explicitly requested for non-dry-run saves' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include(
      'operation' => 'create',
      'local_commit' => true,
      'status' => 'local_committed',
      'remote_commit' => false,
      'remote_mutation_allowed' => false
    )
    expect(payload.fetch('errors')).to eq([])
    expect(Telephony::ProvisioningRun.count).to eq(0)
  end

  it 'keeps distinct Asterisk analog lines on separate provider connections for different hosts' do
    first_payload = create_payload_variant(
      display_phone_number: '+17770001001',
      provider_account_number: 'analog-1001',
      ingress_number: 'analog-1001',
      source: 'virtual_pbx_ui'
    ).merge(provider_kind: 'asterisk_analog', channel_name: 'Analog line 1001')
    first_payload[:connection].merge!(host: '10.77.0.5', port: 5070, transport: 'tcp')
    second_payload = create_payload_variant(
      display_phone_number: '+177' + '7000' + '1002',
      provider_account_number: 'analog-1002',
      ingress_number: 'analog-1002',
      source: 'virtual_pbx_ui'
    ).merge(provider_kind: 'asterisk_analog', channel_name: 'Analog line 1002')
    second_payload[:connection].merge!(host: '10.88.0.5', port: 5060, transport: 'udp')

    post base_path, params: first_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    expect(response).to have_http_status(:ok)

    post base_path, params: second_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    expect(response).to have_http_status(:ok)

    connection_names = account.telephony_provider_connections.order(:name).pluck(:name)
    expect(connection_names).to contain_exactly(
      "trunk-asterisk-analog-acct-#{account.id}-analog-1001",
      "trunk-asterisk-analog-acct-#{account.id}-analog-1002"
    )
    expect(account.telephony_provider_connections.order(:name).pluck(:host, :port, :transport)).to eq([
                                                                                                        ['10.77.0.5', 5070, 'tcp'],
                                                                                                        ['10.88.0.5', 5060, 'udp']
                                                                                                      ])
    expect(account.telephony_number_bindings.order(:ingress_number).pluck(:trunk_ref)).to eq([
                                                                                               "trunk-asterisk-analog-acct-#{account.id}-analog-1001",
                                                                                               "trunk-asterisk-analog-acct-#{account.id}-analog-1002"
                                                                                             ])
  end

  it 'stores the OneLink runtime app ref in local Sipuni channel configuration' do
    with_modified_env(
      TELEPHONY_BRIDGE_RUNTIME_APP_REF: 'onelink-runtime-app-ref',
      TELEPHONY_BRIDGE_DEFAULT_APP_REF: nil
    ) do
      post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    end

    expect(response).to have_http_status(:ok)
    inbox = Inbox.find(response.parsed_body.dig('payload', 'ui_config', 'inbox_id'))
    provider_config = inbox.channel.provider_config_hash.with_indifferent_access
    number_binding = inbox.telephony_number_binding

    expect(provider_config[:app_ref]).to eq('onelink-runtime-app-ref')
    expect(provider_config[:runtime_app_ref]).to eq('onelink-runtime-app-ref')
    expect(number_binding.app_ref).to eq('onelink-runtime-app-ref')
    expect(number_binding.runtime_app_ref).to eq('onelink-runtime-app-ref')
  end

  it 'keeps remote mutation disabled by default for non-dry-run saves' do
    expect(Telephony::VirtualPbx::RemoteProvisioner).not_to receive(:new)

    post base_path, params: valid_create_payload.merge(dry_run: false), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include(
      'operation' => 'create',
      'local_commit' => true,
      'status' => 'local_committed',
      'remote_commit' => false,
      'remote_mutation_allowed' => false
    )
    expect(Telephony::ProvisioningRun.count).to eq(0)
  end

  it 'blocks remote Sipuni create without shared provider credentials before local records are committed' do
    payload = valid_create_payload.deep_dup
    payload.delete(:provider_account_number)
    payload[:connection].delete(:username)
    payload[:connection].delete(:password)
    counts_before = local_record_counts
    bridge_client = instance_double(Telephony::BridgeClient)
    allow(Telephony::BridgeClient).to receive(:new).and_return(bridge_client)
    allow(bridge_client).to receive(:get).with('/telephony/trunks/trunk-sipuni-onelink-out').and_return({})
    allow(bridge_client).to receive(:get).with('/telephony/trunks').and_return({ 'items' => [] })
    expect(Telephony::VirtualPbx::RemoteProvisioner).not_to receive(:new)

    post base_path, params: payload.merge(dry_run: false, remote_commit: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include(
      'operation' => 'create',
      'dry_run' => false,
      'local_commit' => false,
      'status' => 'blocked'
    )
    expect(body.fetch('errors').map { |error| error['code'] }).to include('missing_sipuni_gateway_credentials')
    expect(local_record_counts).to eq(counts_before)
  end

  it 'adopts an existing shared Sipuni connection username instead of deriving it from the provider number' do
    provisioner = instance_double(Telephony::VirtualPbx::RemoteProvisioner)
    captured_args = nil
    bridge_client = instance_double(Telephony::BridgeClient)
    allow(Telephony::BridgeClient).to receive(:new).and_return(bridge_client)
    allow(bridge_client).to receive(:get).with('/telephony/trunks/trunk-sipuni-onelink-out').and_return(
      { 'ref' => 'trunk-sipuni-onelink-out', 'outboundCredentialsRef' => 'cred-shared-sipuni' }
    )
    allow(bridge_client).to receive(:get).with('/telephony/trunks').and_return(
      {
        'items' => [
          {
            'ref' => 'trunk-sipuni-onelink-out',
            'outboundCredentials' => { 'ref' => 'cred-shared-sipuni', 'username' => 'shared-sipuni-login' }
          }
        ]
      }
    )
    allow(Telephony::VirtualPbx::RemoteProvisioner).to receive(:new).and_return(provisioner)
    allow(provisioner).to receive(:execute) do |args|
      captured_args = args
      {
        status: 'succeeded',
        remote_commit: true,
        provisioning_run: { status: 'succeeded' },
        executed_operations: []
      }
    end
    payload = valid_create_payload.deep_dup
    payload[:connection].delete(:username)
    payload[:connection].delete(:password)

    post base_path, params: payload.merge(dry_run: false, remote_commit: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(captured_args.dig(:desired_state, :connection, :username)).to eq('shared-sipuni-login')
    expect(captured_args.dig(:desired_state, :connection, :credentials_ref)).to eq('cred-shared-sipuni')
    expect(captured_args.dig(:plan, :operations).map { |operation| operation[:key] }).not_to include('upsert_connection_credentials')
    expect(captured_args.dig(:plan, :operations).map { |operation| operation[:key] }).to include('upsert_sipuni_gateway')
  end

  it 'passes transient employee SIP passwords into remote provisioning during settings update' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    Inbox.find(inbox_id).inbox_members.find_or_create_by!(user_id: agent.id)

    provisioner = instance_double(Telephony::VirtualPbx::RemoteProvisioner)
    captured_args = nil
    allow(Telephony::VirtualPbx::RemoteProvisioner).to receive(:new).and_return(provisioner)
    allow(provisioner).to receive(:execute) do |args|
      captured_args = args
      {
        status: 'succeeded',
        remote_commit: true,
        provisioning_run: { status: 'succeeded' },
        executed_operations: []
      }
    end

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: true,
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '207',
              sip_username: 'manager-207-login',
              sip_password: 'raw-profile-password',
              availability_mode: 'browser_webphone',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    desired_profile = captured_args.dig(:desired_state, :profiles).first
    expect(desired_profile).to include(
      sip_username: 'manager-207-login',
      sip_password: 'raw-profile-password',
      credentials_ref: "cred-profile-#{account.id}-#{agent.id}-207",
      agent_aor: 'sip:207@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone'
    )
    expect(captured_args.dig(:plan, :operations).map { |operation| operation[:key] }).to include(
      'upsert_agent_credentials',
      'upsert_agent'
    )
    expect(captured_args.fetch(:plan).to_json).not_to include('raw-profile-password')
    expect(response.parsed_body.to_json).not_to include('raw-profile-password')
  end

  it 'defaults Asterisk analog employee profiles to provider-managed external extensions without SIP credentials' do
    create_payload = valid_create_payload.deep_dup.merge(
      provider_kind: 'asterisk_analog',
      channel_name: 'Analog line 9098',
      provider_account_number: '9098',
      ingress_number: '9098',
      connection: {
        host: '10.77.0.5',
        port: 5060,
        transport: 'udp'
      }
    )
    post base_path, params: create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    Inbox.find(inbox_id).inbox_members.find_or_create_by!(user_id: agent.id)

    provisioner = instance_double(Telephony::VirtualPbx::RemoteProvisioner)
    captured_args = nil
    allow(Telephony::VirtualPbx::RemoteProvisioner).to receive(:new).and_return(provisioner)
    allow(provisioner).to receive(:execute) do |args|
      captured_args = args
      {
        status: 'succeeded',
        remote_commit: true,
        provisioning_run: { status: 'succeeded' },
        executed_operations: []
      }
    end

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: true,
          connection: {
            host: '10.77.0.5',
            port: 5070,
            transport: 'tcp'
          },
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '9098',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    desired_profile = captured_args.dig(:desired_state, :profiles).first
    expect(desired_profile).to include(
      internal_extension: '9098',
      agent_aor: 'sip:9098@10.77.0.5',
      availability_mode: 'external_extension'
    )
    expect(captured_args.dig(:desired_state, :connection)).to include(
      host: '10.77.0.5',
      port: 5070,
      transport: 'tcp'
    )
    expect(desired_profile).not_to include(:sip_username, :sip_password, :credentials_ref)
    expect(captured_args.dig(:plan, :operations).map { |operation| operation[:key] }).to include(
      'upsert_trunk', 'upsert_number', 'update_number_route'
    )
    expect(captured_args.dig(:plan, :operations).map { |operation| operation[:key] }).not_to include(
      'upsert_agent', 'upsert_agent_credentials'
    )
  end

  it 'rejects unsupported provider kinds during dry-run without changing local records' do
    counts_before = local_record_counts

    post base_path, params: valid_create_payload.merge(provider_kind: 'twilio'), headers: headers, as: :json

    expect(local_record_counts).to eq(counts_before)
    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'create', 'dry_run' => true, 'valid' => false)
    expect(payload.fetch('errors').map { |error| error['code'] }).to include('provider_kind_invalid')
  end

  it 'rejects non-numeric SIP ports during dry-run without falling back to defaults' do
    payload = valid_create_payload.deep_dup
    payload[:connection][:port] = '5060abc'

    post base_path, params: payload, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('operation' => 'create', 'dry_run' => true, 'valid' => false)
    expect(body.fetch('errors').map { |error| error['code'] }).to include('connection_port_invalid')
  end

  it 'rejects SIP profile users outside the current account during settings assignment' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    other_account = create(:account)
    outsider = create(:user, account: other_account, role: :agent)

    put "#{base_path}/#{inbox_id}",
        params: {
          profiles: [
            {
              user_id: outsider.id,
              internal_extension: '207',
              sip_username: '056124100014',
              sip_password: 'do-not-return-this-profile-secret',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('operation' => 'update', 'dry_run' => true, 'valid' => false)
    expect(body.fetch('errors').map { |error| error['code'] }).to include('profile_user_not_in_account')
  end

  it 'rejects SIP profile assignment before the user is an inbox collaborator' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')

    put "#{base_path}/#{inbox_id}",
        params: {
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '207',
              sip_username: '056124100014',
              sip_password: 'do-not-return-this-profile-secret',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('operation' => 'update', 'dry_run' => true, 'valid' => false)
    expect(body.fetch('errors').map { |error| error['code'] }).to include('profile_user_not_in_inbox')
  end

  it 'creates a managed local Virtual PBX bundle when dry_run is explicitly disabled' do
    counts_before = local_record_counts

    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    inbox_id = payload.dig('ui_config', 'inbox_id')
    expect(payload).to include(
      'operation' => 'create',
      'dry_run' => false,
      'local_commit' => true,
      'remote_commit' => false,
      'remote_mutation_allowed' => false
    )
    expect(local_record_counts).to include(
      voice_channels: counts_before[:voice_channels] + 1,
      inboxes: counts_before[:inboxes] + 1,
      number_bindings: counts_before[:number_bindings] + 1,
      routing_policies: counts_before[:routing_policies] + 1,
      agent_bindings: counts_before[:agent_bindings],
      provider_connections: counts_before[:provider_connections] + 1,
      sip_profiles: counts_before[:sip_profiles]
    )
    expect(payload.dig('ui_config', 'status', 'read_only')).to be(false)
    expect(payload.dig('ui_config', 'connection', 'configured')).to be(true)
    inbox = Inbox.find(inbox_id)
    expect(inbox.inbox_members).to be_empty
    expect(inbox.telephony_sip_profiles).to be_empty
    expect(Telephony::NumberBinding.find_by!(inbox_id: inbox_id)).to be_managed
    expect(payload.to_json).not_to include('do-not-return-this-secret')

    get "#{base_path}/#{inbox_id}", headers: headers

    show_payload = response.parsed_body.fetch('payload')
    expect(show_payload.to_json).not_to include('do-not-return-this-secret')
  end

  it 'creates supplied Sipuni employee profiles as provider-managed extensions during channel creation' do
    post base_path,
         params: valid_create_payload.merge(
           dry_run: false,
           remote_commit: false,
           profiles: [
             {
               user_id: agent.id,
               internal_extension: '207',
               sip_username: 'manager-207-login',
               sip_password: 'do-not-return-this-profile-secret',
               enabled: true
             }
           ]
         ),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    inbox = Inbox.find(inbox_id)
    profile = inbox.telephony_sip_profiles.find_by!(user_id: agent.id)

    expect(inbox.inbox_members.pluck(:user_id)).to include(agent.id)
    expect(profile).to have_attributes(
      internal_extension: '207',
      sip_username: 'manager-207-login',
      sip_host: 'ats01.kz.sipuni.com',
      agent_aor: 'sip:207@ats01.kz.sipuni.com',
      availability_mode: 'external_extension'
    )
    expect(response.parsed_body.to_json).not_to include('do-not-return-this-profile-secret')
  end

  it 'binds employee extensions to existing inbox collaborators during settings update' do
    second_agent = create(:user, account: account, role: :agent)
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    inbox = Inbox.find(inbox_id)
    inbox.inbox_members.find_or_create_by!(user_id: agent.id)
    inbox.inbox_members.find_or_create_by!(user_id: second_agent.id)

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: false,
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '207',
              sip_username: 'manager-207-login',
              sip_password: 'do-not-return-this-profile-secret',
              enabled: true
            },
            {
              user_id: second_agent.id,
              internal_extension: '208',
              sip_username: 'manager-208-login',
              sip_password: 'do-not-return-second-profile-secret',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(inbox.reload.inbox_members.pluck(:user_id)).to contain_exactly(agent.id, second_agent.id)
    expect(inbox.telephony_sip_profiles.pluck(:user_id, :internal_extension, :sip_username)).to contain_exactly(
      [agent.id, '207', 'manager-207-login'],
      [second_agent.id, '208', 'manager-208-login']
    )
    expect(response.parsed_body.to_json).not_to include('do-not-return-this-profile-secret')
    expect(response.parsed_body.to_json).not_to include('do-not-return-second-profile-secret')
    first_profile = inbox.telephony_sip_profiles.find_by!(user_id: agent.id)
    first_profile.update!(credentials_ref: "legacy-secret-ref-#{first_profile.id}")
    credentials_before = inbox.telephony_sip_profiles.index_by(&:user_id).transform_values do |profile|
      [profile.sip_username, profile.password_secret_ref, profile.credentials_ref]
    end
    profile_ids_before = inbox.telephony_sip_profiles.index_by(&:user_id).transform_values(&:id)

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: false,
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '207',
              enabled: true
            },
            {
              user_id: second_agent.id,
              internal_extension: '208',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'errors')).to eq([])
    expect(inbox.reload.telephony_sip_profiles.pluck(:user_id, :internal_extension, :sip_username)).to contain_exactly(
      [agent.id, '207', 'manager-207-login'],
      [second_agent.id, '208', 'manager-208-login']
    )
    credentials_after = inbox.telephony_sip_profiles.index_by(&:user_id).transform_values do |profile|
      [profile.sip_username, profile.password_secret_ref, profile.credentials_ref]
    end
    expect(credentials_after).to eq(credentials_before)

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: false,
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '217',
              enabled: true
            },
            {
              user_id: second_agent.id,
              internal_extension: '208',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'errors')).to eq([])
    expect(inbox.reload.telephony_sip_profiles.pluck(:user_id, :internal_extension, :sip_username)).to contain_exactly(
      [agent.id, '217', 'manager-207-login'],
      [second_agent.id, '208', 'manager-208-login']
    )
    expect(inbox.telephony_sip_profiles.index_by(&:user_id).transform_values(&:id)).to eq(profile_ids_before)
    credentials_after_extension_change = inbox.telephony_sip_profiles.index_by(&:user_id).transform_values do |profile|
      [profile.sip_username, profile.password_secret_ref, profile.credentials_ref]
    end
    expect(credentials_after_extension_change).to eq(credentials_before)

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: false,
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '217',
              sip_username: 'manager-207-login',
              enabled: true
            },
            {
              user_id: second_agent.id,
              internal_extension: '208',
              sip_username: 'manager-208-login',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'errors')).to eq([])
    credentials_after_username_only = inbox.reload.telephony_sip_profiles.index_by(&:user_id).transform_values do |profile|
      [profile.sip_username, profile.password_secret_ref, profile.credentials_ref]
    end
    expect(credentials_after_username_only).to eq(credentials_before)

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: false,
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '217',
              sip_username: '056124100099',
              enabled: true
            },
            {
              user_id: second_agent.id,
              internal_extension: '208',
              sip_username: '056124100015',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'valid')).to be(false)
    expect(response.parsed_body.dig('payload', 'errors').map { |error| error['code'] }).to include(
      'profile_sip_credentials_pair_required'
    )
    credentials_after_username_change_without_password = inbox.reload.telephony_sip_profiles.index_by(&:user_id).transform_values do |profile|
      [profile.sip_username, profile.password_secret_ref, profile.credentials_ref]
    end
    expect(credentials_after_username_change_without_password).to eq(credentials_before)

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: false,
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '217',
              sip_username: '',
              enabled: true
            },
            {
              user_id: second_agent.id,
              internal_extension: '208',
              sip_username: nil,
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    profile_credentials = inbox.reload.telephony_sip_profiles.pluck(
      :user_id, :internal_extension, :sip_username, :password_secret_ref, :credentials_ref
    )
    expect(profile_credentials).to contain_exactly(
      [agent.id, '217', nil, nil, nil],
      [second_agent.id, '208', nil, nil, nil]
    )

    put "#{base_path}/#{inbox_id}",
        params: { dry_run: false, remote_commit: false, channel_name: 'Renamed Sipuni line' },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(inbox.reload.telephony_sip_profiles.pluck(:user_id, :internal_extension, :sip_username)).to contain_exactly(
      [agent.id, '217', nil],
      [second_agent.id, '208', nil]
    )
  end

  # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
  it 'reassigns an existing Sipuni extension to another collaborator without requiring the SIP password again' do
    replacement_agent = create(:user, account: account, role: :agent)
    second_agent = create(:user, account: account, role: :agent)
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    inbox = Inbox.find(inbox_id)
    inbox.inbox_members.find_or_create_by!(user_id: agent.id)
    inbox.inbox_members.find_or_create_by!(user_id: second_agent.id)
    inbox.inbox_members.find_or_create_by!(user_id: replacement_agent.id)

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: false,
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '504',
              sip_username: '056124100020',
              sip_password: 'first-profile-secret',
              enabled: true
            },
            {
              user_id: second_agent.id,
              internal_extension: '505',
              sip_username: '056124100021',
              sip_password: 'second-profile-secret',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'errors')).to eq([])
    original_profile = inbox.reload.telephony_sip_profiles.find_by!(user_id: second_agent.id, internal_extension: '505')
    original_profile.update!(
      credentials_ref: 'remote-credentials-505',
      fonoster_agent_ref: 'remote-agent-505',
      fonoster_credentials_ref: 'remote-credentials-505'
    )
    original_snapshot = original_profile.slice(
      :id,
      :internal_extension,
      :sip_username,
      :password_secret_ref,
      :credentials_ref,
      :fonoster_agent_ref,
      :fonoster_credentials_ref
    )

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: false,
          profiles: [
            {
              user_id: agent.id,
              internal_extension: '504',
              enabled: true
            },
            {
              user_id: replacement_agent.id,
              internal_extension: '505',
              sip_username: '056124100021',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'errors')).to eq([])
    reassigned_profile = inbox.reload.telephony_sip_profiles.find_by!(internal_extension: '505')
    reassigned_snapshot = reassigned_profile.slice(
      :id,
      :internal_extension,
      :sip_username,
      :password_secret_ref,
      :credentials_ref,
      :fonoster_agent_ref,
      :fonoster_credentials_ref
    )
    expect(reassigned_profile.user_id).to eq(replacement_agent.id)
    expect(reassigned_snapshot).to eq(original_snapshot)
    expect(inbox.telephony_sip_profiles.where(user_id: second_agent.id, internal_extension: '505')).to be_empty
  end
  # rubocop:enable RSpec/ExampleLength, RSpec/MultipleExpectations

  it 'recomputes the pinned operator AOR when profile settings replace the prior extension' do
    post base_path,
         params: valid_create_payload.merge(
           dry_run: false,
           remote_commit: false,
           profiles: [
             {
               user_id: agent.id,
               internal_extension: '504',
               sip_username: '056124100014',
               sip_password: 'do-not-return-this-profile-secret',
               availability_mode: 'browser_webphone',
               enabled: true
             }
           ],
           routing: {
             operator_distribution_mode: 'targeted'
           }
         ),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    inbox = Inbox.find(inbox_id)
    expect(inbox.telephony_number_binding.routing_policy.operator_agent_aor).to eq('sip:504@operator.cloud.vconsult.kz')
    old_profile = inbox.telephony_sip_profiles.find_by!(user_id: agent.id)
    old_profile.update!(
      fonoster_agent_ref: 'old-remote-agent-ref',
      fonoster_credentials_ref: 'old-remote-credentials-ref',
      credentials_ref: 'old-remote-credentials-ref'
    )

    second_agent = create(:user, account: account, role: :agent)
    inbox.inbox_members.find_or_create_by!(user_id: second_agent.id)

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          remote_commit: false,
          profiles: [
            {
              user_id: second_agent.id,
              internal_extension: '505',
              sip_username: '056124100015',
              sip_password: 'do-not-return-second-profile-secret',
              availability_mode: 'browser_webphone',
              enabled: true
            }
          ]
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'errors')).to eq([])
    expect(response.parsed_body.dig('payload', 'provisioning_plan', 'operations').map { |operation| operation['key'] }).to include(
      'delete_stale_agent',
      'delete_stale_agent_credentials',
      'delete_stale_sipuni_gateway'
    )
    policy = inbox.reload.telephony_number_binding.routing_policy
    expect(policy.operator_agent_aor).to eq('sip:505@operator.cloud.vconsult.kz')
    expect(inbox.channel.provider_config_hash['operator_agent_aor']).to eq('sip:505@operator.cloud.vconsult.kz')
    expect(inbox.telephony_sip_profiles.pluck(:user_id, :internal_extension)).to contain_exactly(
      [second_agent.id, '505']
    )
  end

  it 'returns a product-level status contract for a managed local bundle without raw telephony internals' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')

    get "#{base_path}/#{inbox_id}/status", headers: headers

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include(
      'operation' => 'status',
      'remote_commit' => false,
      'mutation_allowed' => false,
      'ready' => true,
      'status' => 'ready'
    )
    expect(payload.dig('ui_config', 'inbox_id')).to eq(inbox_id)
    expect(payload.dig('ui_config', 'channel')).to include('name' => 'Sipuni external line')
    expect(payload.dig('ui_config', 'channel', 'display_phone_number')).to be_present
    expect(payload.dig('ui_config', 'connection')).to include(
      'provider_kind' => 'sipuni',
      'remote_mutations' => 'requires_approval'
    )
    expect(payload).not_to have_key('config')
    expect(payload).not_to have_key('bridge_operations')
    expect(payload.to_json).not_to include('trunk_ref')
    expect(payload.to_json).not_to include('credentials_ref')
    expect(payload.to_json).not_to include('agent_aor')
    expect(payload.to_json).not_to include('sip_username')
    expect(payload.fetch('warnings')).to be_an(Array)
  end

  it 'keeps raw Virtual PBX diagnostics behind an explicit diagnostics flag' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')

    get "#{base_path}/#{inbox_id}/status", params: { include_diagnostics: true }, headers: headers

    expect(response).to have_http_status(:ok)
    diagnostics = response.parsed_body.dig('payload', 'diagnostics')
    expect(diagnostics.dig('config', 'resources', 'number_ref')).to eq('sipuni-internal-asterisk-056124100014')
    expect(diagnostics.dig('config', 'resources', 'provider_connection')).to be_present
  end

  it 'returns a product-level provisioning plan during dry-run without bridge operations by default' do
    post base_path, params: valid_create_payload, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'create', 'dry_run' => true, 'valid' => true)
    expect(payload.dig('provisioning_plan', 'remote_mutations')).to eq('requires_approval')
    expect(payload.dig('provisioning_plan', 'items').map { |item| item['code'] }).to include(
      'validate_settings',
      'save_channel',
      'connect_number',
      'configure_routing',
      'remote_sync'
    )
    expect(payload).not_to have_key('bridge_operations')
    expect(payload).not_to have_key('generated_refs')
    expect(payload.to_json).not_to include('/telephony/trunks/')
    expect(payload.to_json).not_to include('/telephony/credentials/')
  end

  it 'updates a managed local bundle without remote writes' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')

    put "#{base_path}/#{inbox_id}",
        params: { dry_run: false, remote_commit: false, channel_name: 'Renamed Sipuni line', routing: { fallback_mode: 'operator' } },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'update', 'local_commit' => true, 'remote_commit' => false)
    expect(payload.dig('ui_config', 'channel', 'name')).to eq('Renamed Sipuni line')
    expect(Inbox.find(inbox_id).name).to eq('Renamed Sipuni line')
  end

  it 'blocks managed local updates while the channel has active calls' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    inbox = Inbox.find(inbox_id)
    number_binding = Telephony::NumberBinding.find_by!(inbox_id: inbox_id)
    conversation = create(:conversation, account: account, inbox: inbox)
    create(
      :telephony_call_session,
      account: account,
      inbox: inbox,
      conversation: conversation,
      number_binding: number_binding,
      status: 'created'
    )

    put "#{base_path}/#{inbox_id}",
        params: { dry_run: false, remote_commit: false, channel_name: 'Blocked rename' },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'update', 'dry_run' => true, 'valid' => false)
    expect(payload.fetch('errors').map { |error| error['code'] }).to include('active_calls_present')
    expect(inbox.reload.name).to eq('Sipuni external line')
  end

  it 'rejects managed local updates that would reuse another channel number ref' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    first_inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    first_binding = Telephony::NumberBinding.find_by!(inbox_id: first_inbox_id)

    second_payload = create_payload_variant(
      display_phone_number: '+15558671002',
      provider_account_number: '056124100015',
      ingress_number: '056124100015'
    )
    post base_path, params: second_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    second_inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    second_binding = Telephony::NumberBinding.find_by!(inbox_id: second_inbox_id)

    put "#{base_path}/#{first_inbox_id}",
        params: {
          dry_run: false,
          remote_commit: false,
          display_phone_number: '+15558671003',
          provider_account_number: '056124100015',
          ingress_number: '056124100015'
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'update', 'dry_run' => true, 'valid' => false)
    expect(payload.fetch('errors').map { |error| error['code'] }).to include('number_ref_taken')
    expect(first_binding.reload.number_ref).not_to eq(second_binding.number_ref)
  end

  it 'deletes only a managed local bundle when explicitly confirmed' do
    counts_before = local_record_counts
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    binding = Telephony::NumberBinding.find_by!(inbox_id: inbox_id)
    run = create(
      :telephony_provisioning_run,
      account: account,
      inbox_id: inbox_id,
      number_binding: binding,
      provider_connection: binding.provider_connection,
      operation: 'update'
    )

    delete "#{base_path}/#{inbox_id}", params: { confirm: true, dry_run: false, remote_commit: false }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'delete', 'local_commit' => true, 'deleted' => true, 'remote_commit' => false)
    expect(payload.fetch('deleted_inbox_id')).to eq(inbox_id)
    expect(local_record_counts).to include(counts_before)
    expect(run.reload).to have_attributes(inbox_id: nil, number_binding_id: nil, provider_connection_id: nil)
  end

  it 'deletes managed local bundle with communication thread links' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    inbox = Inbox.find(inbox_id)
    conversation = create(:conversation, account: account, inbox: inbox)
    thread = create(:communication_thread, account: account, contact: conversation.contact)
    link = create(
      :communication_thread_conversation,
      account: account,
      communication_thread: thread,
      conversation: conversation,
      inbox: inbox,
      contact_inbox: conversation.contact_inbox
    )
    deal = create(:crm_deal, account: account, originating_communication_thread: thread)
    assignment_policy = create(:assignment_policy, account: account)
    decision_log = create(
      :assignment_decision_log,
      account: account,
      inbox: inbox,
      conversation: conversation,
      assignment_policy: assignment_policy
    )

    delete "#{base_path}/#{inbox_id}", params: { confirm: true, dry_run: false, remote_commit: false }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'delete', 'local_commit' => true, 'deleted' => true, 'remote_commit' => false)
    expect(Inbox.exists?(inbox_id)).to be(false)
    expect(CommunicationThreadConversation.exists?(link.id)).to be(false)
    expect(CommunicationThread.exists?(thread.id)).to be(false)
    expect(deal.reload.originating_communication_thread_id).to be_nil
    expect(AssignmentDecisionLog.exists?(decision_log.id)).to be(false)
  end

  it 'blocks managed local delete when an aliased active call normalizes to a canonical active status' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    inbox = Inbox.find(inbox_id)
    number_binding = Telephony::NumberBinding.find_by!(inbox_id: inbox_id)
    conversation = create(:conversation, account: account, inbox: inbox)
    create(
      :telephony_call_session,
      account: account,
      inbox: inbox,
      conversation: conversation,
      number_binding: number_binding,
      status: 'initiated'
    )

    delete "#{base_path}/#{inbox_id}", params: { confirm: true, dry_run: false, remote_commit: false }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'delete', 'dry_run' => true, 'valid' => false)
    expect(payload.fetch('errors').map { |error| error['code'] }).to include('active_calls_present')
    expect(Inbox.exists?(inbox_id)).to be(true)
  end

  it 'keeps a shared provider connection when deleting one managed local channel' do
    shared_source = 'shared-sipuni-provider'
    first_payload = valid_create_payload.deep_dup.merge(metadata: { source: shared_source })
    second_payload = create_payload_variant(
      display_phone_number: '+15558671004',
      provider_account_number: '056124100016',
      ingress_number: '056124100016',
      source: shared_source
    )

    post base_path, params: first_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    first_inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    provider_connection = Telephony::NumberBinding.find_by!(inbox_id: first_inbox_id).provider_connection

    post base_path, params: second_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    expect(response).to have_http_status(:ok), response.parsed_body.to_json
    second_inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    expect(second_inbox_id).to be_present, response.parsed_body.to_json
    second_binding = Telephony::NumberBinding.find_by!(inbox_id: second_inbox_id)

    expect(second_binding.provider_connection_id).to eq(provider_connection.id)

    delete "#{base_path}/#{first_inbox_id}", params: { confirm: true, dry_run: false, remote_commit: false }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(Telephony::ProviderConnection.exists?(provider_connection.id)).to be(true)
    expect(second_binding.reload.provider_connection_id).to eq(provider_connection.id)
  end

  it 'keeps legacy delete as a dry-run and blocks non-managed resources' do
    voice_channel = create_reference_channel
    counts_before = local_record_counts

    delete "#{base_path}/#{voice_channel.inbox.id}", params: { confirm: true }, headers: headers, as: :json

    expect(local_record_counts).to eq(counts_before)
    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'delete', 'dry_run' => true, 'valid' => false)
    expect(payload.fetch('errors').map { |error| error['code'] }).to include('managed_ownership_required')
  end
end
