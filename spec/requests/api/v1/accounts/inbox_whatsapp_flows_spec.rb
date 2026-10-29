require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::InboxWhatsappFlowsController', type: :request do
  let(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:secret_api_key) { 'EAASuperSecretGraphToken123456' }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end
  let(:inbox) { channel.inbox }
  let(:base_path) { "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/whatsapp_flows" }
  let(:json_headers) { { 'Content-Type' => 'application/json' } }

  before do
    channel.update!(
      provider_config: channel.provider_config.merge(
        'api_key' => secret_api_key,
        'phone_number_id' => '111222333',
        'business_account_id' => '987654321'
      )
    )
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('FRONTEND_URL', '').and_return('https://app.onelink.kz')
  end

  describe 'authentication, authorization, and channel guard' do
    it 'rejects unauthenticated requests with 401' do
      get base_path
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects non-admin agents with 401' do
      get base_path, headers: agent.create_new_auth_token
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects non-WhatsApp-Cloud inboxes with 400' do
      legacy_channel = create(
        :channel_whatsapp,
        account: account,
        phone_number: '+77019991122',
        provider: 'default',
        sync_templates: false,
        validate_provider_config: false
      )

      get "/api/v1/accounts/#{account.id}/inboxes/#{legacy_channel.inbox.id}/whatsapp_flows",
          headers: admin.create_new_auth_token

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'POST /setup_encryption and GET /' do
    it 'generates an encrypted RSA keypair, uploads public key to Meta, and never leaks secrets in JSON' do
      stub_request(:post, %r{https://graph\.facebook\.com/.*/111222333/whatsapp_business_encryption})
        .to_return(status: 200, body: { success: true }.to_json, headers: json_headers)

      post "#{base_path}/setup_encryption", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:ok)
      flows_cfg = response.parsed_body.dig('provider_config', 'whatsapp_flows')
      expect(flows_cfg['encryption_status']).to eq('configured')
      expect(flows_cfg.keys).not_to include('encrypted_private_key', 'endpoint_secret', 'public_key_pem')

      stored = channel.reload.provider_config['whatsapp_flows']
      expect(stored.values_at('encrypted_private_key', 'endpoint_secret')).to all(be_present)
    end

    it 'returns sanitized public whatsapp_flows state on GET /' do
      Whatsapp::Flows::ManagementService.new(whatsapp_channel: channel).ensure_local_credentials!

      get base_path, headers: admin.create_new_auth_token

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['whatsapp_flows']).to include('encryption_status' => 'pending_upload')
      expect(response.parsed_body['whatsapp_flows'].keys)
        .not_to include('encrypted_private_key', 'endpoint_secret', 'public_key_pem')
    end

    it 'sanitizes provider tokens from error messages when Meta rejects public key upload' do
      stub_request(:post, %r{https://graph\.facebook\.com/.*/111222333/whatsapp_business_encryption})
        .to_return(
          status: 400,
          body: { error: { message: "Invalid request with token #{secret_api_key}", code: 100 } }.to_json,
          headers: json_headers
        )

      post "#{base_path}/setup_encryption", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include(secret_api_key)
      expect(response.parsed_body['error']).to include('[FILTERED]')
    end
  end

  describe 'POST /provision_booking and POST /:id/publish' do
    it 'provisions a booking Flow with custom labels' do
      stub_request(:post, %r{https://graph\.facebook\.com/.*/111222333/whatsapp_business_encryption})
        .to_return(status: 200, body: { success: true }.to_json, headers: json_headers)
      stub_request(:post, %r{https://graph\.facebook\.com/.*/987654321/flows})
        .to_return(status: 200, body: { id: 'flow_booking_1' }.to_json, headers: json_headers)
      stub_request(:post, %r{https://graph\.facebook\.com/.*/flow_booking_1/assets})
        .to_return(status: 200, body: { success: true, validation_errors: [] }.to_json, headers: json_headers)

      post "#{base_path}/provision_booking",
           params: { whatsapp_flow: { locale: 'ru', publish: false, specialist_label: 'Врач', service_label: 'Услуга' } },
           headers: admin.create_new_auth_token

      expect(response).to have_http_status(:created)
      flows_cfg = response.parsed_body.dig('provider_config', 'whatsapp_flows')
      expect(flows_cfg['booking_flow_id']).to eq('flow_booking_1')
      expect(flows_cfg['flows'].first).to include('id' => 'flow_booking_1', 'status' => 'DRAFT', 'kind' => 'booking', 'locale' => 'ru')
    end

    it 'publishes a DRAFT Flow and updates cached status to PUBLISHED' do
      channel.update!(
        provider_config: channel.provider_config.merge(
          'whatsapp_flows' => {
            'flows' => [{ 'id' => 'flow_booking_1', 'name' => 'Онлайн-запись', 'status' => 'DRAFT', 'kind' => 'booking' }]
          }
        )
      )
      stub_request(:post, %r{https://graph\.facebook\.com/.*/flow_booking_1/publish})
        .to_return(status: 200, body: { success: true }.to_json, headers: json_headers)

      post "#{base_path}/flow_booking_1/publish", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('provider_config', 'whatsapp_flows', 'flows', 0, 'status')).to eq('PUBLISHED')
    end
  end

  describe 'POST /sync and DELETE /:id' do
    it 'syncs Flows from Meta and reconciles booking_flow_id' do
      stub_request(:get, %r{https://graph\.facebook\.com/.*/987654321/flows})
        .to_return(
          status: 200,
          body: {
            data: [
              { id: 'flow_booking_1', name: 'Онлайн-запись', status: 'PUBLISHED', categories: ['APPOINTMENT_BOOKING'] },
              { id: 'flow_draft_2', name: 'Черновик', status: 'DRAFT', categories: ['SURVEY'] }
            ]
          }.to_json,
          headers: json_headers
        )

      post "#{base_path}/sync", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:ok)
      flows_cfg = response.parsed_body.dig('provider_config', 'whatsapp_flows')
      expect(flows_cfg['flows'].map { |f| f['id'] }).to eq(%w[flow_booking_1 flow_draft_2])
      expect(flows_cfg['booking_flow_id']).to eq('flow_booking_1')
    end

    it 'deletes a DRAFT Flow via Meta DELETE' do
      channel.update!(
        provider_config: channel.provider_config.merge(
          'whatsapp_flows' => {
            'flows' => [{ 'id' => 'flow_draft_2', 'name' => 'Черновик', 'status' => 'DRAFT' }]
          }
        )
      )
      stub_request(:delete, %r{https://graph\.facebook\.com/.*/flow_draft_2})
        .to_return(status: 200, body: { success: true }.to_json, headers: json_headers)

      delete "#{base_path}/flow_draft_2", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('provider_config', 'whatsapp_flows', 'flows')).to eq([])
    end

    it 'deprecates a PUBLISHED Flow via Meta POST /:id/deprecate instead of deleting it' do
      channel.update!(
        provider_config: channel.provider_config.merge(
          'whatsapp_flows' => {
            'booking_flow_id' => 'flow_booking_1',
            'flows' => [{ 'id' => 'flow_booking_1', 'name' => 'Онлайн-запись', 'status' => 'PUBLISHED', 'kind' => 'booking' }]
          }
        )
      )
      stub_request(:post, %r{https://graph\.facebook\.com/.*/flow_booking_1/deprecate})
        .to_return(status: 200, body: { success: true }.to_json, headers: json_headers)

      delete "#{base_path}/flow_booking_1", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:ok)
      flows_cfg = response.parsed_body.dig('provider_config', 'whatsapp_flows')
      expect(flows_cfg['flows'].first['status']).to eq('DEPRECATED')
      expect(flows_cfg['booking_flow_id']).to be_nil
    end

    it 'follows Graph API paging.next cursor pagination on POST /sync' do
      next_page_url = 'https://graph.facebook.com/v22.0/987654321/flows?after=cursor_page_2'
      stub_request(:get, %r{\Ahttps://graph\.facebook\.com/v\d+\.\d+/987654321/flows\?fields=})
        .to_return(
          status: 200,
          body: {
            data: [{ id: 'flow_page_1', name: 'Page 1 Flow', status: 'PUBLISHED', categories: ['APPOINTMENT_BOOKING'] }],
            paging: { next: next_page_url }
          }.to_json,
          headers: json_headers
        )
      stub_request(:get, %r{\Ahttps://graph\.facebook\.com/v\d+\.\d+/987654321/flows\?after=cursor_page_2})
        .to_return(
          status: 200,
          body: {
            data: [{ id: 'flow_page_2', name: 'Page 2 Flow', status: 'DRAFT', categories: ['SURVEY'] }]
          }.to_json,
          headers: json_headers
        )

      post "#{base_path}/sync", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body.dig('provider_config', 'whatsapp_flows', 'flows').map { |f| f['id'] }
      expect(ids).to eq(%w[flow_page_1 flow_page_2])
    end

    it 'deprecates THROTTLED Flows instead of calling DELETE and exposes sanitized whatsapp_flows to non-admin agents on inbox list' do
      create(:inbox_member, inbox: inbox, user: agent)
      channel.update!(
        provider_config: channel.provider_config.merge(
          'whatsapp_flows' => {
            'endpoint_secret' => 'super_secret_ep_token_123456',
            'encrypted_private_key' => 'secret_cipher_blob',
            'booking_flow_id' => 'flow_throttled_1',
            'flows' => [{ 'id' => 'flow_throttled_1', 'name' => 'Запись', 'status' => 'THROTTLED', 'kind' => 'booking' }]
          }
        )
      )

      get "/api/v1/accounts/#{account.id}/inboxes", headers: agent.create_new_auth_token
      expect(response).to have_http_status(:ok)
      agent_inbox = response.parsed_body['payload'].find { |item| item['id'] == inbox.id }
      expect(agent_inbox['provider_config']).to be_nil
      expect(agent_inbox['whatsapp_flows']).to include('booking_flow_id' => 'flow_throttled_1')
      expect(agent_inbox['whatsapp_flows'].keys).not_to include('endpoint_secret', 'encrypted_private_key')
    end

    it 'calls deprecate endpoint when removing a THROTTLED Flow' do
      channel.update!(
        provider_config: channel.provider_config.merge(
          'whatsapp_flows' => {
            'flows' => [{ 'id' => 'flow_throttled_1', 'name' => 'Запись', 'status' => 'THROTTLED' }]
          }
        )
      )
      stub_request(:post, %r{https://graph\.facebook\.com/.*/flow_throttled_1/deprecate})
        .to_return(status: 200, body: { success: true }.to_json, headers: json_headers)

      delete "#{base_path}/flow_throttled_1", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('provider_config', 'whatsapp_flows', 'flows', 0, 'status')).to eq('DEPRECATED')
    end

    it 'records last_publish_error on the cached DRAFT flow when immediate publish fails in Meta' do
      stub_request(:post, %r{https://graph\.facebook\.com/.*/111222333/whatsapp_business_encryption})
        .to_return(status: 200, body: { success: true }.to_json, headers: json_headers)
      stub_request(:post, %r{https://graph\.facebook\.com/.*/987654321/flows})
        .to_return(status: 200, body: { id: 'flow_unpub_1' }.to_json, headers: json_headers)
      stub_request(:post, %r{https://graph\.facebook\.com/.*/flow_unpub_1/assets})
        .to_return(status: 200, body: { success: true, validation_errors: [] }.to_json, headers: json_headers)
      stub_request(:post, %r{https://graph\.facebook\.com/.*/flow_unpub_1/publish})
        .to_return(
          status: 400,
          body: { error: { error_user_msg: 'Endpoint health check failed' } }.to_json,
          headers: json_headers
        )

      post "#{base_path}/provision_booking",
           params: { whatsapp_flow: { locale: 'ru', publish: true } },
           headers: admin.create_new_auth_token

      expect(response).to have_http_status(:created)
      created_flow = response.parsed_body.dig('provider_config', 'whatsapp_flows', 'flows', 0)
      expect(created_flow).to include('id' => 'flow_unpub_1', 'status' => 'DRAFT', 'last_publish_error' => 'Endpoint health check failed')
    end
  end
end
