require 'rails_helper'

RSpec.describe 'Channel sync policy', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:support) { create(:super_admin).tap { |user| create(:account_user, account: account, user: user, role: :administrator) } }
  let(:telegram) { create(:channel_telegram_personal, account: account) }
  let(:whatsapp) { create(:channel_whatsapp_web, account: account) }
  let(:headers) { admin.create_new_auth_token }

  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-key') { example.run }
  end

  def support_headers
    grant = SuperAdmin::ImpersonationService.issue_grant!(actor: support, account: account, target_user: admin)
    raw = SuperAdmin::ImpersonationService.grant_for(user: admin, token: grant.token)
    expect(SuperAdmin::ImpersonationService.consume_grant!(user: admin, token: grant.token, grant: raw)).to be(true)
    admin.create_new_auth_token(grant.client_id)
  end

  def telegram_path(action, channel = telegram)
    "/api/v1/accounts/#{channel.account_id}/inboxes/#{channel.inbox.id}/telegram_personal_#{action}"
  end

  describe 'manual support operations' do
    %w[history_sync contacts_sync].each do |action|
      it "denies ordinary administrators #{action} before invoking the gateway" do
        expect(TelegramPersonal::GatewayClient).not_to receive(:new)
        post telegram_path(action), headers: headers, params: { reset_cursor: true }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it "denies agents #{action} even with a personal API token" do
        expect(TelegramPersonal::GatewayClient).not_to receive(:new)
        post telegram_path(action), headers: { 'Authorization' => "Bearer #{agent.access_token.token}" }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'does not accept a browser-supplied support context or a technical administrator flag' do
      expect(TelegramPersonal::GatewayClient).not_to receive(:new)
      post telegram_path('history_sync'), headers: headers, params: {
        captain_platform_access: true,
        super_admin_impersonation: { type: 'super_admin_impersonation', actor_id: support.id, account_id: account.id }
      }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'denies ordinary administrator personal API tokens' do
      expect(TelegramPersonal::GatewayClient).not_to receive(:new)
      post telegram_path('contacts_sync'), headers: { 'api-access-token' => admin.access_token.token }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'allows a direct platform support personal API token' do
      gateway = instance_double(TelegramPersonal::GatewayClient, sync_channel!: {}, contacts_sync!: {})
      allow(TelegramPersonal::GatewayClient).to receive(:new).with(channel: telegram).and_return(gateway)
      post telegram_path('contacts_sync'), headers: { 'Authorization' => "Bearer #{support.access_token.token}" }, as: :json
      expect(response).to have_http_status(:success)
      expect(gateway).to have_received(:contacts_sync!).with(force: true)
    end

    it 'denies an inactive platform actor even if its personal token still exists' do
      support.update!(confirmed_at: nil)
      expect(TelegramPersonal::GatewayClient).not_to receive(:new)
      post telegram_path('contacts_sync'), headers: { 'Authorization' => "Bearer #{support.access_token.token}" }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'allows a verified support session inside its account' do
      gateway = instance_double(TelegramPersonal::GatewayClient, sync_channel!: {}, history_sync!: {})
      allow(TelegramPersonal::GatewayClient).to receive(:new).with(channel: telegram).and_return(gateway)
      post telegram_path('history_sync'), headers: support_headers, params: { reset_cursor: true, full: true }, as: :json
      expect(response).to have_http_status(:success)
      expect(gateway).to have_received(:history_sync!).with(force: true, reset_cursor: true, include_contacts: false, full: true)
    end

    it 'keeps a verified support session within its selected account' do
      other = create(:channel_telegram_personal)
      create(:account_user, account: other.account, user: admin, role: :administrator)
      expect(TelegramPersonal::GatewayClient).not_to receive(:new)
      post telegram_path('history_sync', other), headers: support_headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects an expired support session before touching the gateway' do
      auth = support_headers
      expect(TelegramPersonal::GatewayClient).not_to receive(:new)
      travel 20.minutes do
        post telegram_path('history_sync'), headers: auth, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'keeps a deleting inbox fenced even for platform support' do
      telegram.inbox.mark_pending_deletion!
      expect(TelegramPersonal::GatewayClient).not_to receive(:new)
      post telegram_path('history_sync'), headers: support.create_new_auth_token, as: :json
      expect(response).to have_http_status(:accepted)
    end

    it 'denies technical WhatsApp repair to a clinic administrator' do
      expect(WhatsappWeb::Providers::EvolutionService).not_to receive(:new)
      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp.inbox.id}/repair_whatsapp_web", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'allows technical WhatsApp repair to verified support' do
      provider = instance_double(WhatsappWeb::Providers::EvolutionService, repair!: true)
      allow(WhatsappWeb::Providers::EvolutionService).to receive(:new).with(channel: whatsapp).and_return(provider)
      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp.inbox.id}/repair_whatsapp_web", headers: support_headers, as: :json
      expect(response).to have_http_status(:success)
      expect(provider).to have_received(:repair!)
    end
  end

  describe 'retired WhatsApp history settings' do
    it 'rejects them on creation before provisioning or creating an inbox' do
      expect do
        post "/api/v1/accounts/#{account.id}/inboxes", headers: headers, params: {
          channel: { type: 'whatsapp_web', phone_number: '+15550000001', import_contacts: false }
        }, as: :json
      end.not_to change(Channel::WhatsappWeb, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include('error' => 'platform_managed_history', 'fields' => ['import_contacts'])
    end

    it 'rejects a mixed update atomically instead of changing its ordinary fields' do
      previous = whatsapp.inbox.name
      patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp.inbox.id}", headers: headers, params: {
        name: 'Must not be saved', channel: { history_lookback_days: 7, import_messages: false }
      }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(whatsapp.inbox.reload.name).to eq(previous)
      expect(response.parsed_body['fields']).to contain_exactly('history_lookback_days', 'import_messages')
    end

    it 'does not return legacy import flags or limits as effective configuration' do
      whatsapp.update!(import_contacts: false, import_messages: false, history_lookback_days: 7)
      get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp.inbox.id}", headers: headers, as: :json
      expect(response).to have_http_status(:success)
      expect(response.parsed_body.keys).not_to include('import_contacts', 'import_messages', 'history_lookback_days')
      expect(whatsapp.reload.attributes.slice('import_contacts', 'import_messages', 'history_lookback_days')).to eq(
        'import_contacts' => false, 'import_messages' => false, 'history_lookback_days' => 7
      )
    end
  end
end
