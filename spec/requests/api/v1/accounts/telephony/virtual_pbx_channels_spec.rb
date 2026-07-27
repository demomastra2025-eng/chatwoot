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
  let(:operator_agent_aor) { 'sip:9098@10.66.66.2' }

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
    expect(payload.dig('provider_templates', 'binotel')).to include(
      'label' => 'Binotel',
      'default_port' => 5060,
      'default_transport' => 'udp',
      'allows_display_ingress_split' => true
    )
    expect(payload.dig('provider_templates', 'beeline')).to include(
      'label' => 'Билайн',
      'default_host' => 'cloudpbx.beeline.kz',
      'default_port' => 5060,
      'default_transport' => 'udp',
      'default_outbound_proxy' => '46.227.186.231:6050',
      'default_codec' => 'pcma',
      'allows_display_ingress_split' => true
    )
  end

  def put_with_configuration_version(path, params:, headers:, as:)
    inbox_id = path.split('/').last
    configuration_version = Telephony::VirtualPbx::ConfigBuilder.new(account: account).for_inbox(inbox_id)[:configuration_version]
    put path,
        params: params.merge(expected_configuration_version: configuration_version),
        headers: headers,
        as: as
  end

  def create_reference_channel
    voice_channel = create(
      :channel_voice,
      :sipuni,
      account: account,
      phone_number: '+17715550123',
      provider_config: {
        number_ref: 'sipuni-internal-asterisk-056124100014',
        app_ref: 'runtime-app-ref',
        trunk_ref: 'trunk-sipuni-onelink-out',
        provider_kind: 'sipuni',
        display_phone_number: '+17715550123',
        ingress_number: '056124100014',
        routing_mode: 'operator',
        operator_agent_aor: operator_agent_aor
      }
    )
    voice_channel.inbox.telephony_number_binding.update!(
      phone_number: '056124100014',
      metadata: {
        provider_kind: 'sipuni',
        ingress_number: '056124100014'
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
      :sipuni,
      account: account,
      phone_number: '+17705550124',
      provider_config: {
        number_ref: 'sipuni-internal-asterisk-056124100014',
        app_ref: 'runtime-app-ref',
        provider_kind: 'sipuni',
        display_phone_number: '+17705550124',
        sipuni_account_number: '056124100014',
        sipuni_ingress_number: '056124100014',
        routing_mode: 'operator',
        operator_agent_aor: operator_agent_aor
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
    expect(body.dig('diagnostics', 'generated_refs', 'number_ref')).to eq("sipuni-sip-device-acct-#{account.id}-ats01-kz-sipuni-com-056124100014")
  end

  it 'keeps Asterisk analog direct SIP channels local-only during create dry-run' do
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
    expect(body.dig('diagnostics', 'payload', 'fonoster_tel_url')).to be_nil
    expect(body.dig('diagnostics', 'payload', 'profiles').first).to include(
      'internal_extension' => '9098',
      'user_id' => agent.id,
      'availability_mode' => 'browser_webphone'
    )
    expect(body.dig('diagnostics', 'payload', 'connection', 'host')).to eq('10.77.0.5')
    expect(body.dig('diagnostics', 'payload', 'connection', 'send_register')).to be(false)
    expect(body.dig('diagnostics', 'generated_refs', 'number_ref')).to eq(
      "asterisk-analog-sip-device-acct-#{account.id}-10-77-0-5-17770005175"
    )
    expect(body.dig('diagnostics', 'generated_refs')).not_to include('trunk_ref')
    expect(body.fetch('diagnostics')).not_to have_key('bridge_operations')
    expect(body.to_json).not_to include('tel:9098')
  end

  it 'builds a create dry-run without changing local records or remote operations' do
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
    expect(payload.fetch('diagnostics')).not_to have_key('bridge_operations')
    expect(payload.dig('diagnostics', 'generated_refs', 'number_ref')).to eq("sipuni-sip-device-acct-#{account.id}-ats01-kz-sipuni-com-056124100014")
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

  it 'defaults Sipuni employee SIP profiles to browser webphone profiles without remote operations' do
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
      'availability_mode' => 'browser_webphone'
    )
    operation_codes = Array(body.dig('diagnostics', 'bridge_operations')).map { |operation| operation['code'] }
    expect(operation_codes).to eq([])
    expect(operation_codes).not_to include('upsert_agent', 'upsert_agent_credentials', 'upsert_sipuni_gateway')
    expect(body.to_json).not_to include('do-not-return-manager-secret')
  end

  it 'accepts Binotel provider-managed SIP profile dry-runs without remote refs' do
    payload = valid_create_payload.deep_dup.merge(
      provider_kind: 'binotel',
      channel_name: 'Binotel external line',
      display_phone_number: '+17770001755',
      provider_account_number: 'binotel-account-9001',
      ingress_number: 'binotel-1755',
      connection: {
        host: 'sip53.binotel.example',
        port: 5060,
        transport: 'udp',
        username: 'binotel-trunk-9001',
        password: 'do-not-return-binotel-secret'
      },
      profiles: [
        {
          user_id: agent.id,
          internal_extension: '207',
          availability_mode: 'external_extension',
          enabled: true
        }
      ]
    )

    post base_path, params: payload.merge(include_diagnostics: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    operation_codes = Array(body.dig('diagnostics', 'bridge_operations')).map { |operation| operation['code'] }

    expect(body).to include('operation' => 'create', 'dry_run' => true, 'valid' => true)
    expect(body.dig('diagnostics', 'provider_template', 'label')).to eq('Binotel')
    expect(body.dig('diagnostics', 'payload', 'profiles').first).to include(
      'internal_extension' => '207',
      'user_id' => agent.id,
      'availability_mode' => 'external_extension'
    )
    expect(body.dig('diagnostics', 'generated_refs')).to include(
      'number_ref' => "binotel-sip-device-acct-#{account.id}-sip53-binotel-example-binotel-account-9001"
    )
    expect(body.dig('diagnostics', 'generated_refs')).not_to include('trunk_ref')
    expect(operation_codes).to eq([])
    expect(operation_codes).not_to include('upsert_sipuni_gateway', 'upsert_agent', 'upsert_agent_credentials')
    expect(body.to_json).not_to include('do-not-return-binotel-secret')
  end

  it 'creates Binotel host-only channels as local native voice channels' do
    payload = valid_create_payload.deep_dup.merge(
      provider_kind: 'binotel',
      channel_name: '+77000781755',
      display_phone_number: '+77000781755',
      provider_account_number: '+77000781755',
      ingress_number: '+77000781755',
      connection: {
        host: 'sip53.binotel.com'
      },
      routing: {
        mode: 'operator',
        fallback_mode: 'reject',
        operator_distribution_mode: 'broadcast'
      },
      metadata: { source: 'virtual_pbx_ui' }
    )

    post base_path, params: payload.merge(dry_run: false, remote_commit: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')

    expect(body).to include(
      'operation' => 'create',
      'dry_run' => false,
      'valid' => true,
      'local_commit' => true,
      'remote_commit' => false,
      'status' => 'local_committed'
    )
    inbox = Inbox.find(body.dig('ui_config', 'inbox_id'))
    expect(inbox.channel.provider).to eq('binotel')
    expect(inbox.channel.provider_config_hash.with_indifferent_access).to include(
      provider_kind: 'binotel',
      number_ref: "binotel-sip-device-acct-#{account.id}-sip53-binotel-com-77000781755"
    )
    expect(inbox.telephony_number_binding).to have_attributes(
      provider: 'binotel',
      app_ref: nil,
      trunk_ref: nil,
      fonoster_tel_url: nil
    )
    expect(body.dig('provisioning_plan', 'operations')).to eq([])
    expect(body.dig('provisioning_plan', 'items')).to all(include('status' => 'ready'))
  end

  it 'creates Beeline Cloud PBX channels with domain, proxy, UDP, and PCMA settings' do
    payload = valid_create_payload.deep_dup.merge(
      provider_kind: 'beeline',
      channel_name: 'Beeline Cloud PBX',
      display_phone_number: '+77000001001',
      provider_account_number: '1001',
      ingress_number: '1001',
      connection: {
        host: 'cloudpbx.beeline.kz',
        port: 5060,
        transport: 'udp',
        sip_domain: 'vpbx-company-test.cloudpbx.beeline.kz',
        outbound_proxy: '46.227.186.231:6050',
        codec: 'pcma'
      },
      metadata: { source: 'virtual_pbx_ui' }
    )

    post base_path, params: payload.merge(dry_run: false, remote_commit: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body.fetch('errors')).to eq([])
    inbox = Inbox.find(body.dig('ui_config', 'inbox_id'))
    connection = inbox.telephony_number_binding.provider_connection

    expect(body).to include(
      'operation' => 'create',
      'dry_run' => false,
      'valid' => true,
      'local_commit' => true,
      'remote_commit' => false,
      'status' => 'local_committed'
    )
    expect(inbox.channel.provider).to eq('beeline')
    expect(connection).to have_attributes(
      provider_kind: 'beeline',
      host: 'cloudpbx.beeline.kz',
      port: 5060,
      transport: 'udp'
    )
    expect(connection.metadata).to include(
      'sip_domain' => 'vpbx-company-test.cloudpbx.beeline.kz',
      'outbound_proxy' => '46.227.186.231:6050',
      'codec' => 'pcma'
    )
  end

  it 'rejects Beeline settings that violate the fixed UDP and PCMA contract' do
    payload = valid_create_payload.deep_dup.merge(
      provider_kind: 'beeline',
      connection: {
        host: 'cloudpbx.beeline.kz',
        port: 5070,
        transport: 'tcp',
        sip_domain: 'vpbx-company-test.cloudpbx.beeline.kz',
        outbound_proxy: 'proxy.cloudpbx.beeline.kz:6050',
        codec: 'pcmu'
      }
    )

    post base_path, params: payload.merge(dry_run: true, remote_commit: false), headers: headers, as: :json

    body = response.parsed_body.fetch('payload')
    expect(response).to have_http_status(:ok)
    expect(body['valid']).to be(false)
    expect(body.fetch('errors').pluck('code')).to include(
      'beeline_port_invalid',
      'beeline_transport_invalid',
      'beeline_codec_invalid'
    )
  end

  it 'accepts local-only create dry-run without shared provider credentials for Sipuni' do
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

  it 'ignores remote commit for native Sipuni create without SIP device credentials' do
    payload = valid_create_payload.deep_dup
    payload[:connection].delete(:username)
    payload[:connection].delete(:password)
    counts_before = local_record_counts

    post base_path, params: payload.merge(dry_run: false, remote_commit: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include(
      'operation' => 'create',
      'dry_run' => false,
      'valid' => true,
      'status' => 'local_committed',
      'local_commit' => true,
      'remote_commit' => false,
      'mutation_reason' => 'local_janus_sip_commit'
    )
    expect(body.fetch('errors')).to eq([])
    expect(body.dig('provisioning_plan', 'operations')).to eq([])
    expect(local_record_counts[:inboxes]).to eq(counts_before[:inboxes] + 1)
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
    first_payload[:metadata][:outbound_dial_format] = 'strip_plus'
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
      "asterisk-analog-sip-device-acct-#{account.id}-10-77-0-5-analog-1001",
      "asterisk-analog-sip-device-acct-#{account.id}-10-88-0-5-analog-1002"
    )
    expect(account.telephony_provider_connections.order(:name).pluck(:host, :port, :transport)).to eq([
                                                                                                        ['10.77.0.5', 5070, 'tcp'],
                                                                                                        ['10.88.0.5', 5060, 'udp']
                                                                                                      ])
    expect(account.telephony_provider_connections.order(:name).pluck(:metadata)).to match([
                                                                                            hash_including('outbound_dial_format' => 'strip_plus'),
                                                                                            hash_including('outbound_dial_format' => 'kz_trunk')
                                                                                          ])
    expect(account.telephony_number_bindings.order(:ingress_number).pluck(:trunk_ref)).to eq([nil, nil])
  end

  it 'does not store OneLink bridge refs in local Sipuni channel configuration' do
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

    expect(provider_config[:app_ref]).to be_nil
    expect(provider_config[:runtime_app_ref]).to be_nil
    expect(provider_config[:trunk_ref]).to be_nil
    expect(provider_config[:fonoster_tel_url]).to be_nil
    expect(number_binding.app_ref).to be_nil
    expect(number_binding.runtime_app_ref).to be_nil
    expect(number_binding.trunk_ref).to be_nil
    expect(number_binding.fonoster_tel_url).to be_nil
  end

  it 'clears legacy bridge refs when a Binotel channel is updated' do
    provider_connection = create(:telephony_provider_connection, account: account, provider_kind: 'binotel')
    voice_channel = create(
      :channel_voice,
      account: account,
      provider: 'binotel',
      phone_number: '+17770005555',
      provider_config: {
        provider_kind: 'binotel',
        provider_connection_id: provider_connection.id,
        number_ref: 'legacy-binotel-number-ref',
        app_ref: 'legacy-app-ref',
        runtime_app_ref: 'legacy-runtime-app-ref',
        trunk_ref: 'legacy-trunk-ref',
        fonoster_tel_url: 'tel:+17770005555',
        fonoster_number_ref: 'legacy-fonoster-number-ref',
        operator_agent_ref: 'legacy-operator-agent-ref',
        display_phone_number: '+17770005555',
        provider_account_number: '+17770005555',
        ingress_number: '+17770005555',
        routing_mode: 'operator',
        fallback_mode: 'reject',
        managed_by: 'onelink',
        ownership_status: 'local'
      }
    )
    voice_channel.inbox.inbox_members.find_or_create_by!(user_id: agent.id)

    put_with_configuration_version "#{base_path}/#{voice_channel.inbox.id}",
                                   params: {
                                     dry_run: false,
                                     remote_commit: true,
                                     provider_kind: 'binotel',
                                     channel_name: '+17770005555',
                                     display_phone_number: '+17770005555',
                                     provider_account_number: '+17770005555',
                                     ingress_number: '+17770005555',
                                     connection: { host: 'sip53.binotel.com' },
                                     routing: {
                                       mode: 'operator',
                                       fallback_mode: 'reject',
                                       operator_distribution_mode: 'broadcast'
                                     },
                                     profiles: [
                                       {
                                         user_id: agent.id,
                                         internal_extension: '901',
                                         sip_username: 'pq4dyw5f',
                                         sip_password: 'do-not-return-binotel-profile-secret',
                                         availability_mode: 'browser_webphone',
                                         enabled: true
                                       }
                                     ]
                                   },
                                   headers: headers,
                                   as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('status' => 'local_committed', 'remote_commit' => false)
    expect(body.dig('provisioning_plan', 'operations')).to eq([])

    inbox = voice_channel.inbox.reload
    provider_config = inbox.channel.provider_config_hash.with_indifferent_access
    provider_connection = inbox.telephony_number_binding.provider_connection
    profile = inbox.telephony_sip_profiles.find_by!(user_id: agent.id)

    expect(inbox.channel.provider).to eq('binotel')
    expect(provider_config.values_at(:app_ref, :runtime_app_ref, :trunk_ref, :fonoster_tel_url, :fonoster_number_ref,
                                     :operator_agent_ref)).to all(be_nil)
    expect(provider_connection).to have_attributes(fonoster_trunk_ref: nil, fonoster_credentials_ref: nil)
    expect(inbox.telephony_number_binding).to have_attributes(
      app_ref: nil,
      runtime_app_ref: nil,
      trunk_ref: nil,
      fonoster_tel_url: nil
    )
    expect(profile).to have_attributes(
      fonoster_agent_ref: nil,
      fonoster_credentials_ref: nil,
      sip_host: 'sip53.binotel.com'
    )
    expect(body.to_json).not_to include('do-not-return-binotel-profile-secret')
  end

  it 'accepts a legacy Virtual PBX PATCH without a configuration version' do
    post base_path, params: valid_create_payload.merge(dry_run: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')

    put "#{base_path}/#{inbox_id}",
        params: {
          dry_run: false,
          virtual_pbx_channel: { channel_name: 'Legacy client channel name' }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(Inbox.find(inbox_id).name).to eq('Legacy client channel name')
  end

  it 'rejects a stale Virtual PBX PATCH without overwriting a newer configuration' do
    post base_path, params: valid_create_payload.merge(dry_run: false), headers: headers, as: :json
    ui_config = response.parsed_body.dig('payload', 'ui_config')
    inbox = Inbox.find(ui_config.fetch('inbox_id'))
    stale_version = ui_config.fetch('configuration_version')
    inbox.update!(name: 'Newer channel name')

    put "#{base_path}/#{inbox.id}",
        params: {
          dry_run: false,
          expected_configuration_version: stale_version,
          virtual_pbx_channel: { channel_name: 'Stale channel name' }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('VIRTUAL_PBX_CONFIGURATION_STALE')
    expect(inbox.reload.name).to eq('Newer channel name')
  end

  it 'keeps remote mutation disabled by default for non-dry-run saves' do
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

  it 'keeps Sipuni create local-only even when remote commit is requested' do
    payload = valid_create_payload.deep_dup
    payload.delete(:provider_account_number)
    payload[:connection].delete(:username)
    payload[:connection].delete(:password)
    counts_before = local_record_counts

    post base_path, params: payload.merge(dry_run: false, remote_commit: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include(
      'operation' => 'create',
      'dry_run' => false,
      'local_commit' => true,
      'status' => 'local_committed',
      'remote_commit' => false
    )
    expect(body.fetch('errors')).to eq([])
    expect(body.dig('provisioning_plan', 'operations')).to eq([])
    expect(local_record_counts[:inboxes]).to eq(counts_before[:inboxes] + 1)
  end

  it 'does not create bridge refs for native Sipuni local-only create' do
    payload = valid_create_payload.deep_dup
    payload[:connection].delete(:username)
    payload[:connection].delete(:password)

    post base_path, params: payload.merge(dry_run: false, remote_commit: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    inbox = Inbox.find(response.parsed_body.dig('payload', 'ui_config', 'inbox_id'))
    provider_connection = inbox.telephony_number_binding.provider_connection
    expect(provider_connection).to have_attributes(
      username: nil,
      fonoster_credentials_ref: nil,
      fonoster_trunk_ref: nil
    )
    expect(inbox.telephony_number_binding).to have_attributes(
      app_ref: nil,
      trunk_ref: nil,
      fonoster_tel_url: nil
    )
    expect(response.parsed_body.dig('payload', 'provisioning_plan', 'operations')).to eq([])
  end

  it 'stores transient employee SIP passwords in native Sipuni profiles without remote provisioning' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    Inbox.find(inbox_id).inbox_members.find_or_create_by!(user_id: agent.id)

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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
    profile = Inbox.find(inbox_id).telephony_sip_profiles.find_by!(user_id: agent.id)
    expect(profile).to have_attributes(
      sip_username: 'manager-207-login',
      credentials_ref: "cred-profile-#{account.id}-#{agent.id}-207",
      agent_aor: 'sip:manager-207-login@ats01.kz.sipuni.com',
      availability_mode: 'browser_webphone'
    )
    expect(profile.sip_password).to eq('raw-profile-password')
    expect(profile.fonoster_agent_ref).to be_nil
    expect(profile.fonoster_credentials_ref).to be_nil
    expect(response.parsed_body.dig('payload', 'provisioning_plan', 'operations')).to eq([])
    expect(response.parsed_body.fetch('payload')).to include(
      'remote_commit' => false,
      'status' => 'local_committed'
    )
    expect(response.parsed_body.to_json).not_to include('raw-profile-password')
  end

  it 'stores one voice agent SIP profile without assigning an employee' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')

    put_with_configuration_version "#{base_path}/#{inbox_id}",
                                   params: {
                                     dry_run: false,
                                     remote_commit: false,
                                     profiles: [
                                       {
                                         profile_kind: 'voice_agent',
                                         internal_extension: '9098',
                                         sip_username: 'ai-agent-9098',
                                         sip_password: 'raw-ai-profile-password',
                                         availability_mode: 'browser_webphone',
                                         enabled: true
                                       }
                                     ]
                                   },
                                   headers: headers,
                                   as: :json

    expect(response).to have_http_status(:ok)
    profile = Inbox.find(inbox_id).telephony_sip_profiles.find_by!(profile_kind: 'voice_agent')
    expect(profile).to have_attributes(
      user_id: nil,
      internal_extension: '9098',
      sip_username: 'ai-agent-9098',
      credentials_ref: "cred-profile-#{account.id}-voice-agent-9098"
    )
    expect(profile.sip_password).to eq('raw-ai-profile-password')
    expect(response.parsed_body.dig('payload', 'ui_config', 'employees', 0)).to include(
      'profile_kind' => 'voice_agent',
      'voice_agent' => true
    )
    expect(response.parsed_body.to_json).not_to include('raw-ai-profile-password')
  end

  it 'converts an existing employee SIP profile to a voice agent profile by id' do
    post base_path,
         params: valid_create_payload.merge(
           dry_run: false,
           remote_commit: false,
           profiles: [
             {
               profile_kind: 'human_operator',
               user_id: agent.id,
               internal_extension: '9098',
               sip_username: 'agent-9098',
               sip_password: 'raw-agent-profile-password',
               enabled: true
             }
           ]
         ),
         headers: headers,
         as: :json
    inbox = Inbox.find(response.parsed_body.dig('payload', 'ui_config', 'inbox_id'))
    profile = inbox.telephony_sip_profiles.find_by!(user_id: agent.id)

    put_with_configuration_version "#{base_path}/#{inbox.id}",
                                   params: {
                                     dry_run: false,
                                     remote_commit: false,
                                     profiles: [
                                       {
                                         id: profile.id,
                                         profile_kind: 'voice_agent',
                                         internal_extension: '9098',
                                         sip_username: 'ai-agent-9098',
                                         sip_password: 'raw-ai-profile-password',
                                         enabled: true
                                       }
                                     ]
                                   },
                                   headers: headers,
                                   as: :json

    expect(response).to have_http_status(:ok)
    expect(inbox.telephony_sip_profiles.reload.count).to eq(1)
    expect(profile.reload).to have_attributes(
      profile_kind: 'voice_agent',
      user_id: nil,
      internal_extension: '9098',
      sip_username: 'ai-agent-9098'
    )
  end

  it 'converts an existing employee SIP profile to a voice agent without requiring the saved SIP password again' do
    post base_path,
         params: valid_create_payload.merge(
           dry_run: false,
           remote_commit: false,
           profiles: [
             {
               profile_kind: 'human_operator',
               user_id: agent.id,
               internal_extension: '9098',
               sip_username: 'agent-9098',
               sip_password: 'raw-agent-profile-password',
               enabled: true
             }
           ]
         ),
         headers: headers,
         as: :json
    inbox = Inbox.find(response.parsed_body.dig('payload', 'ui_config', 'inbox_id'))
    profile = inbox.telephony_sip_profiles.find_by!(user_id: agent.id)

    put_with_configuration_version "#{base_path}/#{inbox.id}",
                                   params: {
                                     dry_run: false,
                                     remote_commit: false,
                                     profiles: [
                                       {
                                         id: profile.id,
                                         profile_kind: 'voice_agent',
                                         internal_extension: '9098',
                                         sip_username: 'agent-9098',
                                         enabled: true
                                       }
                                     ]
                                   },
                                   headers: headers,
                                   as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'errors')).to eq([])
    expect(profile.reload).to have_attributes(
      profile_kind: 'voice_agent',
      user_id: nil,
      sip_username: 'agent-9098'
    )
    expect(profile.sip_password).to eq('raw-agent-profile-password')
  end

  it 'reuses an existing SIP profile when the form recreates the voice agent row with the same extension' do
    post base_path,
         params: valid_create_payload.merge(
           dry_run: false,
           remote_commit: false,
           profiles: [
             {
               profile_kind: 'human_operator',
               user_id: agent.id,
               internal_extension: '207',
               sip_username: 'agent-207',
               sip_password: 'raw-agent-profile-password',
               enabled: true
             }
           ]
         ),
         headers: headers,
         as: :json
    inbox = Inbox.find(response.parsed_body.dig('payload', 'ui_config', 'inbox_id'))
    old_profile = inbox.telephony_sip_profiles.find_by!(user_id: agent.id)

    put_with_configuration_version "#{base_path}/#{inbox.id}",
                                   params: {
                                     dry_run: false,
                                     remote_commit: false,
                                     profiles: [
                                       {
                                         profile_kind: 'voice_agent',
                                         internal_extension: '207',
                                         sip_username: 'agent-207',
                                         enabled: true
                                       }
                                     ]
                                   },
                                   headers: headers,
                                   as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'errors')).to eq([])
    expect(inbox.telephony_sip_profiles.reload.pluck(:id)).to eq([old_profile.id])
    expect(old_profile.reload).to have_attributes(
      profile_kind: 'voice_agent',
      user_id: nil,
      internal_extension: '207',
      sip_username: 'agent-207'
    )
  end

  it 'rejects multiple voice agent SIP profiles in the same virtual PBX channel' do
    post base_path, params: valid_create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')

    put_with_configuration_version "#{base_path}/#{inbox_id}",
                                   params: {
                                     dry_run: false,
                                     remote_commit: false,
                                     profiles: [
                                       {
                                         profile_kind: 'voice_agent',
                                         internal_extension: '9098',
                                         sip_username: 'ai-agent-9098',
                                         sip_password: 'raw-ai-profile-password',
                                         enabled: true
                                       },
                                       {
                                         profile_kind: 'voice_agent',
                                         internal_extension: '9099',
                                         sip_username: 'ai-agent-9099',
                                         sip_password: 'raw-ai-profile-password-2',
                                         enabled: true
                                       }
                                     ]
                                   },
                                   headers: headers,
                                   as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('validation_failed')
    expect(response.parsed_body.dig('payload', 'errors')).to include(
      include('code' => 'profile_voice_agent_unique_per_inbox')
    )
  end

  it 'defaults Asterisk analog employee profiles to browser webphone and skips remote provisioning' do
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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
    body = response.parsed_body.fetch('payload')
    profile = Inbox.find(inbox_id).telephony_sip_profiles.find_by!(user_id: agent.id)

    expect(body).to include('remote_commit' => false, 'status' => 'local_committed')
    expect(body.dig('provisioning_plan', 'operations')).to eq([])
    expect(profile).to have_attributes(
      internal_extension: '9098',
      agent_aor: 'sip:9098@10.77.0.5',
      availability_mode: 'browser_webphone',
      sip_username: nil,
      fonoster_agent_ref: nil,
      fonoster_credentials_ref: nil
    )
    expect(profile.provider_connection).to have_attributes(
      host: '10.77.0.5',
      port: 5070,
      transport: 'tcp'
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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

  it 'creates supplied Sipuni employee profiles as native browser webphone profiles during channel creation' do
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
      agent_aor: 'sip:manager-207-login@ats01.kz.sipuni.com',
      availability_mode: 'browser_webphone'
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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
      credentials_ref: 'remote-credentials-505'
    )
    original_snapshot = original_profile.slice(
      :id,
      :internal_extension,
      :sip_username,
      :password_secret_ref,
      :credentials_ref
    )

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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
      :credentials_ref
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
    expect(inbox.telephony_number_binding.routing_policy.operator_agent_aor).to eq('sip:056124100014@ats01.kz.sipuni.com')
    old_profile = inbox.telephony_sip_profiles.find_by!(user_id: agent.id)
    old_profile.update!(
      fonoster_agent_ref: 'old-remote-agent-ref',
      fonoster_credentials_ref: 'old-remote-credentials-ref',
      credentials_ref: 'old-remote-credentials-ref'
    )

    second_agent = create(:user, account: account, role: :agent)
    inbox.inbox_members.find_or_create_by!(user_id: second_agent.id)

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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
    expect(response.parsed_body.dig('payload', 'provisioning_plan', 'operations')).to eq([])
    policy = inbox.reload.telephony_number_binding.routing_policy
    expect(policy.operator_agent_aor).to eq('sip:056124100015@ats01.kz.sipuni.com')
    expect(inbox.channel.provider_config_hash['operator_agent_aor']).to eq('sip:056124100015@ats01.kz.sipuni.com')
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
      'remote_mutations' => 'disabled'
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
    expect(diagnostics.dig('config', 'resources', 'number_ref')).to eq("sipuni-sip-device-acct-#{account.id}-ats01-kz-sipuni-com-056124100014")
    expect(diagnostics.dig('config', 'resources', 'provider_connection')).to be_present
  end

  it 'returns a product-level provisioning plan during dry-run without bridge operations by default' do
    post base_path, params: valid_create_payload, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'create', 'dry_run' => true, 'valid' => true)
    expect(payload.dig('provisioning_plan', 'remote_mutations')).to eq('disabled')
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
                                   params: { dry_run: false, remote_commit: false, channel_name: 'Renamed Sipuni line',
                                             routing: { fallback_mode: 'operator' } },
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

    put_with_configuration_version "#{base_path}/#{inbox_id}",
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

    put_with_configuration_version "#{base_path}/#{first_inbox_id}",
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

  it 'keeps the second provider-owned SIP device connection when deleting one managed local channel' do
    first_payload = valid_create_payload.deep_dup
    second_payload = create_payload_variant(
      display_phone_number: '+15558671004',
      provider_account_number: '056124100016',
      ingress_number: '056124100016',
      source: 'second-sipuni-provider'
    )

    post base_path, params: first_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    first_inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    first_provider_connection = Telephony::NumberBinding.find_by!(inbox_id: first_inbox_id).provider_connection

    post base_path, params: second_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    expect(response).to have_http_status(:ok), response.parsed_body.to_json
    second_inbox_id = response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
    expect(second_inbox_id).to be_present, response.parsed_body.to_json
    second_binding = Telephony::NumberBinding.find_by!(inbox_id: second_inbox_id)

    expect(second_binding.provider_connection_id).not_to eq(first_provider_connection.id)

    delete "#{base_path}/#{first_inbox_id}", params: { confirm: true, dry_run: false, remote_commit: false }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(Telephony::ProviderConnection.exists?(first_provider_connection.id)).to be(false)
    expect(Telephony::ProviderConnection.exists?(second_binding.provider_connection_id)).to be(true)
    expect(second_binding.reload.provider_connection_id).to be_present
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
