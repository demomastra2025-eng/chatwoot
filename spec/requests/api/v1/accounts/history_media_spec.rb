require 'rails_helper'

RSpec.describe 'History media reads', type: :request do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-key') { example.run }
  end

  let(:channel) { create(:channel_whatsapp_web) }
  let(:account) { channel.account }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:message) do
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: 'HISTORY_MEDIA', content: 'Caption',
                     content_attributes: { imported_history: true, history_attachment: { unavailable: true, kind: 'image' } })
  end
  let(:path) { "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{message.id}/enrich_media" }

  before do
    create(:inbox_member, inbox: channel.inbox, user: agent)
  end

  it 'allows an ordinary member to load a scoped message and ignores arbitrary URLs' do
    provider = instance_double(WhatsappWeb::Providers::EvolutionService)
    allow(WhatsappWeb::Providers::EvolutionService).to receive(:new).and_return(provider)
    expect(provider).to receive(:fetch_message_by_source_id).with(source_id: 'HISTORY_MEDIA', remote_jid: nil, from_me: false).and_return(
      key: { id: 'HISTORY_MEDIA' }, message: { imageMessage: { mimetype: 'image/png', fileName: 'old.png' } }
    )
    expect(provider).to receive(:fetch_message_media).and_return(
      base64: Base64.strict_encode64(File.binread(Rails.root.join('spec/assets/sample.png'))), mimetype: 'image/png'
    )
    post path, headers: agent.create_new_auth_token, params: { url: 'http://127.0.0.1/private' }, as: :json
    expect(response).to have_http_status(:success)
    expect(response.parsed_body['id']).to eq(message.id)
    expect(response.parsed_body['attachments'].size).to eq(1)
  end

  it 'allows administrator personal API tokens without a support scope' do
    service = instance_double(Messages::EnrichHistoryMediaService, perform: message)
    expect(Messages::EnrichHistoryMediaService).to receive(:new).with(message: message).and_return(service)
    post path, headers: { 'api-access-token' => admin.access_token.token }, as: :json
    expect(response).to have_http_status(:success)
  end

  it 'denies agents who cannot view the conversation before any provider lookup' do
    channel.inbox.inbox_members.where(user: agent).destroy_all
    expect(WhatsappWeb::Providers::EvolutionService).not_to receive(:new)
    post path, headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'scopes message IDs to the conversation' do
    foreign = create(:message)
    expect(WhatsappWeb::Providers::EvolutionService).not_to receive(:new)
    post path.sub("/#{message.id}/enrich_media", "/#{foreign.id}/enrich_media"), headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'scopes the conversation to the current account' do
    foreign = create(:conversation)
    expect(WhatsappWeb::Providers::EvolutionService).not_to receive(:new)
    foreign_path = "/api/v1/accounts/#{foreign.account_id}/conversations/#{foreign.display_id}/messages/#{message.id}/enrich_media"
    post foreign_path, headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not enrich deleted messages or deleting inboxes' do
    message.update!(content_attributes: message.content_attributes.merge(deleted: true))
    expect(WhatsappWeb::Providers::EvolutionService).not_to receive(:new)
    post path, headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    message.update!(content_attributes: { history_attachment: { unavailable: true } })
    channel.inbox.mark_pending_deletion!
    post path, headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns a controlled busy response without a second provider fetch' do
    expect(Messages::EnrichHistoryMediaService).to receive(:new).and_raise(MutexApplicationJob::LockAcquisitionError)
    post path, headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq('error' => 'history_media_busy')
  end

  it 'does not expose provider details in a failed request' do
    expect(Messages::EnrichHistoryMediaService).to receive(:new).and_raise(TelegramPersonal::GatewayClient::GatewayError, 'private provider URL')
    post path, headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq('error' => 'history_media_unavailable')
  end
end
