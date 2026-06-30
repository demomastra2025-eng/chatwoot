require 'rails_helper'

RSpec.describe 'Telephony Virtual PBX remote orchestration API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:base_path) { "/api/v1/accounts/#{account.id}/telephony/virtual_pbx_channels" }
  let(:create_payload) do
    {
      provider_kind: 'sipuni',
      channel_name: 'Sipuni external line',
      display_phone_number: '+17770001234',
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

  before do
    account.enable_features!('channel_voice')
  end

  def create_local_virtual_pbx!
    post base_path, params: create_payload.merge(dry_run: false, remote_commit: false), headers: headers, as: :json
    expect(response).to have_http_status(:ok), response.parsed_body.to_json
    response.parsed_body.dig('payload', 'ui_config', 'inbox_id')
  end

  it 'exposes a product-level provisioning plan without raw secrets or diagnostics by default' do
    inbox_id = create_local_virtual_pbx!

    post "#{base_path}/#{inbox_id}/provisioning_plan", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'provisioning_plan', 'remote_commit' => false)
    expect(payload.dig('provisioning_plan', 'status')).to eq('dry_run_valid')
    expect(payload.dig('ui_config', 'inbox_id')).to eq(inbox_id)
    expect(payload).not_to have_key('config')
    expect(payload.to_json).not_to include('do-not-return-this-secret')
    expect(payload).not_to have_key('diagnostics')
  end

  it 'creates a provider-owned Sipuni SIP device without adopting shared trunk credentials' do
    payload = create_payload.deep_dup
    payload[:connection].delete(:username)
    payload[:connection].delete(:password)
    allow(Telephony::VirtualPbx::RemoteProvisioner).to receive(:new)

    post base_path, params: payload.merge(dry_run: false, remote_commit: true), headers: headers, as: :json

    expect(response).to have_http_status(:ok), response.parsed_body.to_json
    result = response.parsed_body.fetch('payload')
    inbox = Inbox.find(result.dig('ui_config', 'inbox_id'))
    connection = inbox.telephony_number_binding.provider_connection
    expect(result).to include(
      'operation' => 'create',
      'status' => 'local_committed',
      'local_commit' => true,
      'remote_commit' => false,
      'remote_mutation_allowed' => false,
      'remote_mutation_reason' => 'REMOTE_MUTATION_REQUIRES_APPROVAL'
    )
    expect(result.dig('provisioning_plan', 'status')).to eq('dry_run_valid')
    expect(Telephony::VirtualPbx::RemoteProvisioner).not_to have_received(:new)
    expect(connection.username).to be_nil
    expect(connection.password_secret_ref).to be_nil
  end

  it 'runs approved remote provision without an env feature flag' do
    inbox_id = create_local_virtual_pbx!
    provisioner = instance_double(Telephony::VirtualPbx::RemoteProvisioner)
    allow(Telephony::VirtualPbx::RemoteProvisioner).to receive(:new).and_return(provisioner)
    allow(provisioner).to receive(:execute).and_return(
      status: 'succeeded',
      remote_commit: true,
      provisioning_run: { status: 'succeeded' },
      executed_operations: []
    )

    2.times do
      post "#{base_path}/#{inbox_id}/provision", params: { remote_commit: true }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body.fetch('payload')
      expect(payload).to include('operation' => 'provision', 'status' => 'succeeded', 'remote_commit' => true)
      expect(payload.dig('provisioning_run', 'status')).to eq('succeeded')
      expect(payload.to_json).not_to include('do-not-return-this-secret')
    end

    expect(provisioner).to have_received(:execute).twice
  end

  it 'returns sanitized provisioning run history' do
    inbox_id = create_local_virtual_pbx!
    create(
      :telephony_provisioning_run,
      account: account,
      inbox_id: inbox_id,
      requested_by: administrator,
      operation: 'create',
      status: 'blocked',
      error_details: { password: 'do-not-store' }
    )

    get "#{base_path}/#{inbox_id}/provisioning_runs", headers: headers

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('operation' => 'provisioning_runs')
    expect(payload.fetch('provisioning_runs').first).to include('status' => 'blocked', 'operation' => 'create')
    expect(payload.to_json).not_to include('do-not-store')
  end
end
