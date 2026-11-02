require 'rails_helper'

RSpec.describe 'Telegram history media identity on the original endpoint', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:channel) { create(:channel_telegram_personal, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:message) do
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: '901', content: 'Original caption',
                     content_attributes: { imported_history: true, telegram_history_media_incomplete: true })
  end
  let(:gateway) { instance_double(TelegramPersonal::GatewayClient) }
  let(:endpoint) { "/api/v1/accounts/#{account.id}/inboxes/#{channel.inbox.id}/telegram_personal_enrich_media" }

  before do
    allow(TelegramPersonal::GatewayClient).to receive(:new).and_return(gateway)
  end

  boundaries = %i[gateway return]
  %i[channel channel_owner].each do |fence|
    boundaries.each do |boundary|
      it "rejects #{fence} changes at the #{boundary} boundary without returning a foreign message" do
        original_attributes = message.content_attributes.deep_dup
        expected_attributes = original_attributes
        alternate_channel = create(:channel_telegram_personal, account: account)
        alternate_account = create(:account)
        change_context = lambda do
          if fence == :channel
            channel.inbox.update_columns(channel_id: alternate_channel.id) # rubocop:disable Rails/SkipsModelValidations
          else
            channel.update_columns(account_id: alternate_account.id) # rubocop:disable Rails/SkipsModelValidations
          end
          message.update_columns(content: 'FOREIGN_CONTEXT_SECRET') # rubocop:disable Rails/SkipsModelValidations
        end
        allow(gateway).to receive(:enrich_message_media!) do
          change_context.call if boundary == :gateway
          { payload: { message_id: '901', chat_type: 'private', attachments: [] } }
        end
        if boundary == :return
          allow(TelegramPersonal::IncomingMessageService).to receive(:new).and_wrap_original do |original, **arguments|
            service = original.call(**arguments)
            allow(service).to receive(:perform).and_wrap_original do |perform|
              perform.call
              expected_attributes = message.reload.content_attributes.deep_dup
              change_context.call
            end
            service
          end
        end
        expect(Down).not_to receive(:download)

        post endpoint, params: { message_id: message.id }, headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq('error' => 'history_media_unavailable')
        expect(response.body).not_to include('FOREIGN_CONTEXT_SECRET')
        expect(message.reload.attachments).to be_empty
        expect(message.content_attributes).to eq(expected_attributes)
      end
    end
  end

  it 'does not fetch a message outside the authorized inbox' do
    foreign_message = create(:message, content: 'FOREIGN_SCOPE_SECRET')
    expect(gateway).not_to receive(:enrich_message_media!)
    expect(Down).not_to receive(:download)

    post endpoint, params: { message_id: foreign_message.id }, headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(foreign_message.content)
    expect(foreign_message.reload.attachments).to be_empty
  end
end
