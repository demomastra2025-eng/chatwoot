require 'rails_helper'

RSpec.describe 'History media response context', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:other_account) { create(:account) }
  let(:other_conversation) { create(:conversation) }
  let(:media) { { base64: Base64.strict_encode64(File.binread(Rails.root.join('spec/assets/sample.png'))), mimetype: 'image/png' } }

  def change_context(message, fence)
    changes = fence == :owner ? { account_id: other_account.id } : { conversation_id: other_conversation.id }
    message.update!(**changes, content: 'FOREIGN_CONTEXT_SECRET')
  end

  %i[owner conversation].each do |fence|
    it "returns controlled unavailable without a foreign WA body after #{fence} changes in flight" do
      channel = create(:channel_whatsapp_web, account: account)
      conversation = create(:conversation, account: account, inbox: channel.inbox)
      message = create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: 'HTTP_CONTEXT_WA',
                                 content_attributes: { imported_history: true, history_attachment: { unavailable: true, kind: 'image' } })
      original_attributes = message.content_attributes.deep_dup
      provider = instance_double(WhatsappWeb::Providers::EvolutionService)
      allow(WhatsappWeb::Providers::EvolutionService).to receive(:new).and_return(provider)
      allow(provider).to receive(:fetch_message_by_source_id).and_return(
        key: { id: message.source_id }, message: { imageMessage: { mimetype: 'image/png', fileName: 'context.png' } }
      )
      allow(provider).to receive(:fetch_message_media) do
        change_context(message, fence)
        media
      end
      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{message.id}/enrich_media",
           headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'history_media_unavailable')
      expect(response.body).not_to include('FOREIGN_CONTEXT_SECRET')
      expect(message.reload.attachments).to be_empty
      expect(message.content_attributes).to eq(original_attributes)
    end

    it "does not serialize a foreign TG body after #{fence} changes during gateway RPC" do
      channel = create(:channel_telegram_personal, account: account)
      conversation = create(:conversation, account: account, inbox: channel.inbox)
      message = create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: '900',
                                 content_attributes: { imported_history: true, telegram_history_media_incomplete: true })
      gateway = instance_double(TelegramPersonal::GatewayClient)
      allow(TelegramPersonal::GatewayClient).to receive(:new).and_return(gateway)
      allow(gateway).to receive(:enrich_message_media!) do
        change_context(message, fence)
        { payload: { message_id: '900', chat_type: 'private', attachments: [] } }
      end
      expect(Down).not_to receive(:download)
      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{message.id}/enrich_media",
           headers: admin.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'history_media_unavailable')
      expect(response.body).not_to include('FOREIGN_CONTEXT_SECRET')
      expect(message.reload.attachments).to be_empty
    end
  end
end
