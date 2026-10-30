require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::TelegramPersonalChannelsController', type: :request do
  before do
    allow_any_instance_of(AccountUser).to receive(:create_notification_setting)
  end

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_telegram_personal, account: account) }
  let(:inbox) { channel.inbox }

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/telegram_personal_request_code' do
    it 'requests a login code for administrators' do
      allow_any_instance_of(TelegramPersonal::GatewayClient).to receive(:sync_channel!).and_return({})
      allow_any_instance_of(TelegramPersonal::GatewayClient).to receive(:request_login_code!).and_return(
        channel: {
          connection_state: 'connecting',
          lifecycle_state: 'code_sent',
          last_error: nil,
          runtime_state: { lifecycle_state: 'code_sent' }
        }
      )

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_request_code",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['lifecycle_state']).to eq('code_sent')
      expect(response.parsed_body['connection_state']).to eq('connecting')
    end

    it 'rejects non administrators' do
      create(:inbox_member, inbox: inbox, user: agent)

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_request_code",
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns accepted without touching the runtime when the inbox is deleting' do
      inbox.mark_pending_deletion!

      expect_any_instance_of(TelegramPersonal::GatewayClient).not_to receive(:sync_channel!)
      expect_any_instance_of(TelegramPersonal::GatewayClient).not_to receive(:request_login_code!)

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_request_code",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body['deleting']).to eq(true)
      expect(response.parsed_body['lifecycle_state']).to eq('disconnected')
    end

    it 'rejects non telegram personal inboxes' do
      non_telegram_inbox = create(:inbox, account: account)

      post "/api/v1/accounts/#{account.id}/inboxes/#{non_telegram_inbox.id}/telegram_personal_request_code",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to eq(
        'This action is only available for Telegram Personal channels'
      )
    end
  end

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/telegram_personal_request_qr' do
    it 'requests a qr login for administrators' do
      allow_any_instance_of(TelegramPersonal::GatewayClient).to receive(:sync_channel!).and_return({})
      allow_any_instance_of(TelegramPersonal::GatewayClient).to receive(:request_qr_login!).and_return(
        channel: {
          connection_state: 'connected',
          lifecycle_state: 'qr_ready',
          last_error: nil,
          runtime_state: {
            lifecycle_state: 'qr_ready',
            qr_login_url: 'tg://login?token=test-token'
          }
        }
      )

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_request_qr",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['lifecycle_state']).to eq('qr_ready')
      expect(response.parsed_body.dig('runtime_state', 'qr_login_url')).to eq('tg://login?token=test-token')
    end
  end

  describe 'GET /api/v1/accounts/:account_id/inboxes/:id/telegram_personal_diagnostics' do
    it 'returns gateway diagnostics for administrators' do
      allow_any_instance_of(TelegramPersonal::GatewayClient).to receive(:sync_channel!).and_return({})
      allow_any_instance_of(TelegramPersonal::GatewayClient).to receive(:diagnostics).and_return(
        channel: {
          connection_state: 'connected',
          lifecycle_state: 'connected'
        },
        unread_reactions_count: 3
      )

      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_diagnostics",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.dig('channel', 'connection_state')).to eq('connected')
      expect(response.parsed_body['unread_reactions_count']).to eq(3)
    end

    # The gateway snapshot (RuntimeState.snapshot) carries the Telethon session and the hash of a pending login code
    it 'never returns the session string, the login code hash or the dialog ids of the gateway snapshot', :aggregate_failures do
      gateway_client = instance_double(TelegramPersonal::GatewayClient, sync_channel!: {})
      allow(TelegramPersonal::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway_client)
      allow(gateway_client).to receive(:diagnostics).and_return(
        {
          channel: {
            connection_state: 'connected',
            lifecycle_state: 'code_sent',
            last_error: nil,
            string_session: '1BVtsOK8Bu-gateway-session',
            runtime_state: {
              history_sync_state: 'running',
              pending_phone_code_hash: 'gateway-code-hash',
              qr_login_url: 'tg://login?token=gateway-qr',
              history_sync_checkpoint: { dialog_user_ids: %w[700100 700200], next_dialog_index: 1, last_completed_dialog_id: '700100' }
            }
          },
          connected: true,
          me: { id: 42, username: 'owner' }
        }.with_indifferent_access
      )

      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_diagnostics",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      body = response.parsed_body
      expect(response.body).not_to include('1BVtsOK8Bu-gateway-session', 'gateway-code-hash', '700100', '700200')
      expect(body['channel'].keys).to contain_exactly('connection_state', 'lifecycle_state', 'last_error', 'runtime_state')
      expect(body.dig('channel', 'runtime_state')).to include('history_sync_state' => 'running', 'qr_login_url' => 'tg://login?token=gateway-qr')
      expect(body.dig('channel', 'runtime_state', 'history_sync_checkpoint')).to eq('next_dialog_index' => 1)
      expect(body).to include('connected' => true, 'me' => { 'id' => 42, 'username' => 'owner' })
    end

    it 'returns accepted deleting state when the inbox is deleting' do
      inbox.mark_pending_deletion!

      expect_any_instance_of(TelegramPersonal::GatewayClient).not_to receive(:diagnostics)

      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_diagnostics",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body['deleting']).to eq(true)
    end

    it 'returns runtime errors as unprocessable content' do
      gateway_client = instance_double(TelegramPersonal::GatewayClient, sync_channel!: {})
      allow(TelegramPersonal::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway_client)
      allow(gateway_client).to receive(:diagnostics)
        .and_raise(TelegramPersonal::GatewayClient::GatewayError, 'gateway unavailable')

      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_diagnostics",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('gateway unavailable')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/telegram_personal_contacts_sync' do
    it 'requests a contact sync for administrators' do
      allow_any_instance_of(TelegramPersonal::GatewayClient).to receive(:sync_channel!).and_return({})
      expect_any_instance_of(TelegramPersonal::GatewayClient).to receive(:contacts_sync!)
        .with(force: false)
        .and_return(
          channel: {
            connection_state: 'connected',
            lifecycle_state: 'connected',
            last_error: nil,
            runtime_state: { contacts_sync_state: 'scheduled' }
          }
        )

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_contacts_sync",
           params: { force: false },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.dig('runtime_state', 'contacts_sync_state')).to eq('scheduled')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/telegram_personal_verify_code' do
    it 'verifies the login code without forcing a full sync by default' do
      allow_any_instance_of(TelegramPersonal::GatewayClient).to receive(:verify_login_code!).and_return(
        channel: {
          connection_state: 'connected',
          lifecycle_state: 'connected',
          last_error: nil,
          runtime_state: {}
        }
      )
      expect_any_instance_of(TelegramPersonal::GatewayClient).not_to receive(:history_sync!)

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_verify_code",
           params: { code: '12345' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['lifecycle_state']).to eq('connected')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/telegram_personal_history_sync' do
    it 'runs a manual full sync only when reset_cursor is explicitly requested' do
      allow_any_instance_of(TelegramPersonal::GatewayClient).to receive(:sync_channel!).and_return({})
      expect_any_instance_of(TelegramPersonal::GatewayClient).to receive(:history_sync!)
        .with(force: true, reset_cursor: true, include_contacts: true)
        .and_return(
          channel: {
            connection_state: 'connected',
            lifecycle_state: 'connected',
            last_error: nil,
            runtime_state: {
              history_sync_state: 'scheduled',
              history_sync_mode: 'full',
              contacts_sync_state: 'scheduled'
            }
          }
        )

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_history_sync",
           params: { reset_cursor: true, include_contacts: true },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.dig('runtime_state', 'history_sync_mode')).to eq('full')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/telegram_personal_enrich_media' do
    it 'allows assigned inbox agents to enrich historical media on demand' do
      create(:inbox_member, inbox: inbox, user: agent)
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: '6002671687')
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        source_id: '701',
        content: '[Attachment]',
        content_attributes: { 'imported_history' => true, 'telegram_history_media_incomplete' => true }
      )
      service = instance_double(TelegramPersonal::EnrichHistoryMediaService, perform: message)
      expect(TelegramPersonal::EnrichHistoryMediaService).to receive(:new).with(message: message).and_return(service)

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/telegram_personal_enrich_media",
           params: { message_id: message.id },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['id']).to eq(message.id)
    end
  end
end
