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
      },
      profiles: [
        {
          user_id: agent.id,
          internal_extension: '207',
          sip_username: '056124100014',
          sip_password: 'do-not-return-this-profile-secret',
          enabled: true
        }
      ]
    }
  end
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { administrator.create_new_auth_token }
  let(:base_path) { "/api/v1/accounts/#{account.id}/telephony/virtual_pbx_channels" }

  before do
    account.enable_features!('channel_voice')
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

  it 'returns a read-only unified config for a legacy/reference channel' do
    voice_channel = create_reference_channel

    get "#{base_path}/#{voice_channel.inbox.id}", headers: headers

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    config = payload.fetch('config')
    expect(payload).to include('operation' => 'show', 'mutation_allowed' => false)
    expect(config).to include('provider_kind' => 'sipuni', 'ready' => true)
    expect(config.fetch('phone_numbers')).to include(
      'display_phone_number' => '+17715550123',
      'ingress_number' => '056124100014',
      'fonoster_tel_url' => 'tel:056124100014',
      'split_allowed' => true
    )
    expect(config.dig('ownership', 'read_only')).to be(true)
  end

  it 'builds a create dry-run without changing local records or calling the bridge' do
    counts_before = local_record_counts

    post base_path, params: valid_create_payload, headers: headers, as: :json

    expect(local_record_counts).to eq(counts_before)

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include(
      'operation' => 'create',
      'dry_run' => true,
      'valid' => true,
      'remote_commit' => false,
      'mutation_allowed' => false,
      'mutation_reason' => 'phase1_read_only_dry_run'
    )
    expect(payload.dig('generated_refs', 'number_ref')).to eq('sipuni-internal-asterisk-056124100014')
    expect(payload.to_json).not_to include('do-not-return-this-secret')
    expect(payload.to_json).not_to include('do-not-return-this-profile-secret')
    expect(payload.dig('payload', 'connection', 'password')).to eq('[REDACTED]')
    expect(payload.dig('payload', 'profiles', 0, 'sip_password')).to eq('[REDACTED]')
  end

  it 'blocks remote mutation even when a caller asks for remote_commit' do
    post base_path, params: valid_create_payload.merge(remote_commit: true), headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include(
      'code' => 'REMOTE_MUTATION_REQUIRES_APPROVAL',
      'error' => 'Remote Fonoster/Routr mutation requires separate explicit approval'
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

  it 'rejects SIP profile users outside the current account' do
    other_account = create(:account)
    outsider = create(:user, account: other_account, role: :agent)
    payload = valid_create_payload.deep_dup
    payload[:profiles].first[:user_id] = outsider.id

    post base_path, params: payload, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch('payload')
    expect(body).to include('operation' => 'create', 'dry_run' => true, 'valid' => false)
    expect(body.fetch('errors').map { |error| error['code'] }).to include('profile_user_not_in_account')
  end

  it 'creates a managed local Virtual PBX bundle when dry_run is explicitly disabled' do
    counts_before = local_record_counts

    post base_path, params: valid_create_payload.merge(dry_run: false), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    inbox_id = payload.dig('config', 'inbox_id')
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
      sip_profiles: counts_before[:sip_profiles] + 1
    )
    expect(payload.dig('config', 'ownership', 'read_only')).to be(false)
    expect(payload.dig('config', 'resources', 'provider_connection')).to be_present
    expect(Telephony::NumberBinding.find_by!(inbox_id: inbox_id)).to be_managed
    expect(payload.to_json).not_to include('do-not-return-this-secret')
    expect(payload.to_json).not_to include('do-not-return-this-profile-secret')

    get "#{base_path}/#{inbox_id}", headers: headers

    show_payload = response.parsed_body.fetch('payload')
    expect(show_payload.to_json).not_to include('do-not-return-this-secret')
    expect(show_payload.to_json).not_to include('do-not-return-this-profile-secret')
  end

  it 'updates a managed local bundle without remote writes' do
    post base_path, params: valid_create_payload.merge(dry_run: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'config', 'inbox_id')

    put "#{base_path}/#{inbox_id}",
        params: { dry_run: false, channel_name: 'Renamed Sipuni line', routing: { fallback_mode: 'operator' } },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'update', 'local_commit' => true, 'remote_commit' => false)
    expect(payload.dig('config', 'name')).to eq('Renamed Sipuni line')
    expect(Inbox.find(inbox_id).name).to eq('Renamed Sipuni line')
  end

  it 'deletes only a managed local bundle when explicitly confirmed' do
    counts_before = local_record_counts
    post base_path, params: valid_create_payload.merge(dry_run: false), headers: headers, as: :json
    inbox_id = response.parsed_body.dig('payload', 'config', 'inbox_id')

    delete "#{base_path}/#{inbox_id}", params: { confirm: true, dry_run: false }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'delete', 'local_commit' => true, 'deleted' => true, 'remote_commit' => false)
    expect(payload.fetch('deleted_inbox_id')).to eq(inbox_id)
    expect(local_record_counts).to include(counts_before)
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
