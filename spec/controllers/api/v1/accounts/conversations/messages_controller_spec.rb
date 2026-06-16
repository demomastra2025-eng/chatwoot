require 'rails_helper'

RSpec.describe 'Conversation Messages API', type: :request do
  let!(:account) { create(:account) }

  describe 'POST /api/v1/accounts/{account.id}/conversations/<id>/messages' do
    let!(:inbox) { create(:inbox, account: account) }
    let!(:conversation) { create(:conversation, inbox: inbox, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id)

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user with access to conversation' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: conversation.inbox, user: agent)
      end

      it 'creates a new outgoing message' do
        params = { content: 'test-message', private: true }

        post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(conversation.messages.count).to eq(1)
        expect(conversation.messages.first.content).to eq(params[:content])
      end

      it 'does not create the message' do
        params = { content: "#{'h' * 150 * 1000}a", private: true }

        post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_content)

        json_response = response.parsed_body

        expect(json_response['error']).to include(
          I18n.t('errors.messages.too_long', count: 150_000, locale: account.locale)
        )
      end

      it 'rejects official WhatsApp free text outside the reply window without creating a failed message' do
        whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
        whatsapp_inbox = whatsapp_channel.inbox
        whatsapp_conversation = create(:conversation, inbox: whatsapp_inbox, account: account)
        create(
          :message,
          account: account,
          inbox: whatsapp_inbox,
          conversation: whatsapp_conversation,
          message_type: 'incoming',
          created_at: 25.hours.ago
        )
        create(:inbox_member, inbox: whatsapp_inbox, user: agent)

        post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: whatsapp_conversation.display_id),
             params: { content: 'plain text outside window' },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to include('approved channel_template')
        expect(whatsapp_conversation.messages.outgoing).to be_empty
      end

      it 'creates an outgoing text message with a specific bot sender' do
        agent_bot = create(:agent_bot)
        time_stamp = Time.now.utc.to_s
        params = { content: 'test-message', external_created_at: time_stamp, sender_type: 'AgentBot', sender_id: agent_bot.id }

        post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        response_data = response.parsed_body
        expect(response_data['content_attributes']['external_created_at']).to eq time_stamp
        expect(conversation.messages.count).to eq(1)
        expect(conversation.messages.last.sender_id).to eq(agent_bot.id)
        expect(conversation.messages.last.content_type).to eq('text')
      end

      it 'creates a new outgoing message with attachment' do
        file = fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png')
        params = { content: 'test-message', attachments: [file] }

        post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: agent.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(conversation.messages.last.attachments.first.file.present?).to be(true)
        expect(conversation.messages.last.attachments.first.file_type).to eq('image')
      end

      context 'when api inbox' do
        let(:api_channel) { create(:channel_api, account: account) }
        let(:api_inbox) { create(:inbox, channel: api_channel, account: account) }
        let(:conversation) { create(:conversation, inbox: api_inbox, account: account) }

        it 'reopens the conversation with new incoming message' do
          create(:message, conversation: conversation, account: account)
          conversation.resolved!

          params = { content: 'test-message', private: false, message_type: 'incoming' }

          post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id),
               params: params,
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
          expect(conversation.reload.status).to eq('open')
          expect(Conversations::ActivityMessageJob)
            .to(have_been_enqueued.at_least(:once)
              .with(conversation, { account_id: conversation.account_id, inbox_id: conversation.inbox_id, message_type: :activity,
                                    content: 'System reopened the conversation due to a new incoming message.' }))
        end
      end
    end

    context 'when it is an authenticated agent bot' do
      let!(:agent_bot) { create(:agent_bot) }

      it 'creates a new outgoing message' do
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
        params = { content: 'test-message' }

        post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: { api_access_token: agent_bot.access_token.token },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.messages.count).to eq(1)
        expect(conversation.messages.first.content).to eq(params[:content])
      end

      it 'creates a new outgoing input select message' do
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
        select_item1 = build(:bot_message_select)
        select_item2 = build(:bot_message_select)
        params = { content_type: 'input_select', content_attributes: { items: [select_item1, select_item2] } }

        post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: { api_access_token: agent_bot.access_token.token },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.messages.count).to eq(1)
        expect(conversation.messages.first.content_type).to eq(params[:content_type])
        expect(conversation.messages.first.content).to be_nil
      end

      it 'creates a new outgoing cards message' do
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
        card = build(:bot_message_card)
        params = { content_type: 'cards', content_attributes: { items: [card] } }

        post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: conversation.display_id),
             params: params,
             headers: { api_access_token: agent_bot.access_token.token },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.messages.count).to eq(1)
        expect(conversation.messages.first.content_type).to eq(params[:content_type])
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/conversations/:id/messages' do
    let(:conversation) { create(:conversation, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user with access to conversation' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: conversation.inbox, user: agent)
      end

      it 'shows the conversation' do
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(JSON.parse(response.body, symbolize_names: true)[:meta][:contact][:id]).to eq(conversation.contact_id)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/conversations/:conversation_id/messages/:id' do
    let(:message) { create(:message, account: account, content_attributes: { bcc_emails: ['hello@one-link.kz'] }) }
    let(:conversation) { message.conversation }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{message.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user with access to conversation' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: conversation.inbox, user: agent)
      end

      it 'deletes the message' do
        delete "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{message.id}",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(message.reload.content).to eq 'This message was deleted'
        expect(message.reload.deleted).to be true
        expect(message.reload.content_attributes['bcc_emails']).to be_nil
      end

      it 'deletes interactive messages' do
        interactive_message = create(
          :message, message_type: :outgoing, content: 'test', content_type: 'input_select',
                    content_attributes: { 'items' => [{ 'title' => 'test', 'value' => 'test' }] },
                    conversation: conversation
        )

        delete "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{interactive_message.id}",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(interactive_message.reload.deleted).to be true
      end

      it 'deletes telegram personal outgoing messages through provider flow' do
        telegram_channel = create(:channel_telegram_personal, account: account)
        telegram_inbox = telegram_channel.inbox
        telegram_conversation = create(:conversation, account: account, inbox: telegram_inbox)
        telegram_message = create(
          :message,
          account: account,
          inbox: telegram_inbox,
          conversation: telegram_conversation,
          message_type: :outgoing,
          source_id: '555',
          content: 'native telegram message'
        )
        create(:inbox_member, inbox: telegram_inbox, user: agent)

        allow_any_instance_of(Channel::TelegramPersonal).to receive(:delete_message).and_return(true)

        delete "/api/v1/accounts/#{account.id}/conversations/#{telegram_conversation.display_id}/messages/#{telegram_message.id}",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(telegram_message.reload.deleted).to be true
      end

      it 'returns unprocessable when telegram personal provider delete fails' do
        telegram_channel = create(:channel_telegram_personal, account: account)
        telegram_inbox = telegram_channel.inbox
        telegram_conversation = create(:conversation, account: account, inbox: telegram_inbox)
        telegram_message = create(
          :message,
          account: account,
          inbox: telegram_inbox,
          conversation: telegram_conversation,
          message_type: :outgoing,
          source_id: '556',
          content: 'provider error message'
        )
        create(:inbox_member, inbox: telegram_inbox, user: agent)

        allow_any_instance_of(Channel::TelegramPersonal)
          .to receive(:delete_message)
          .and_raise(TelegramPersonal::GatewayClient::GatewayError.new('telegram delete failed'))

        delete "/api/v1/accounts/#{account.id}/conversations/#{telegram_conversation.display_id}/messages/#{telegram_message.id}",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('telegram delete failed')
        expect(telegram_message.reload.deleted).to be_nil
      end
    end

    context 'when the message id is invalid' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: conversation.inbox, user: agent)
      end

      it 'returns not found error' do
        delete "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/99999",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/conversations/:conversation_id/messages/:id' do
    let(:agent) { create(:user, account: account, role: :agent) }

    it 'updates telegram personal outgoing message content' do
      telegram_channel = create(:channel_telegram_personal, account: account)
      telegram_inbox = telegram_channel.inbox
      telegram_conversation = create(:conversation, account: account, inbox: telegram_inbox)
      telegram_message = create(
        :message,
        account: account,
        inbox: telegram_inbox,
        conversation: telegram_conversation,
        message_type: :outgoing,
        source_id: '777',
        content: 'old text'
      )
      create(:inbox_member, inbox: telegram_inbox, user: agent)

      allow_any_instance_of(Channel::TelegramPersonal).to receive(:update_message).and_return(true)

      patch "/api/v1/accounts/#{account.id}/conversations/#{telegram_conversation.display_id}/messages/#{telegram_message.id}",
            params: { content: 'updated telegram text' },
            headers: agent.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:success)
      expect(telegram_message.reload.content).to eq('updated telegram text')
      expect(telegram_message.content_attributes['edited']).to be true
    end

    it 'returns unprocessable when telegram personal conversation has no contact inbox source id' do
      telegram_channel = create(:channel_telegram_personal, account: account)
      telegram_inbox = telegram_channel.inbox
      telegram_conversation = create(
        :conversation,
        account: account,
        inbox: telegram_inbox,
        contact_inbox: nil,
        additional_attributes: {}
      )
      telegram_message = create(
        :message,
        account: account,
        inbox: telegram_inbox,
        conversation: telegram_conversation,
        message_type: :outgoing,
        source_id: '778',
        content: 'old text'
      )
      create(:inbox_member, inbox: telegram_inbox, user: agent)

      patch "/api/v1/accounts/#{account.id}/conversations/#{telegram_conversation.display_id}/messages/#{telegram_message.id}",
            params: { content: 'updated telegram text' },
            headers: agent.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq(
        'Telegram Personal conversation is missing contact inbox source_id'
      )
      expect(telegram_message.reload.content).to eq('old text')
      expect(telegram_message.content_attributes['edited']).to be_nil
    end

    it 'returns unprocessable when telegram personal provider edit fails' do
      telegram_channel = create(:channel_telegram_personal, account: account)
      telegram_inbox = telegram_channel.inbox
      telegram_conversation = create(:conversation, account: account, inbox: telegram_inbox)
      telegram_message = create(
        :message,
        account: account,
        inbox: telegram_inbox,
        conversation: telegram_conversation,
        message_type: :outgoing,
        source_id: '779',
        content: 'old text'
      )
      create(:inbox_member, inbox: telegram_inbox, user: agent)

      allow_any_instance_of(Channel::TelegramPersonal)
        .to receive(:update_message)
        .and_raise(TelegramPersonal::GatewayClient::GatewayError.new('telegram edit failed'))

      patch "/api/v1/accounts/#{account.id}/conversations/#{telegram_conversation.display_id}/messages/#{telegram_message.id}",
            params: { content: 'updated telegram text' },
            headers: agent.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('telegram edit failed')
      expect(telegram_message.reload.content).to eq('old text')
      expect(telegram_message.content_attributes['edited']).to be_nil
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:conversation_id/messages/:id/retry' do
    let(:message) { create(:message, account: account, status: :failed, content_attributes: { external_error: 'error' }) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{message.conversation.display_id}/messages/#{message.id}/retry"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user with access to conversation' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: message.conversation.inbox, user: agent)
      end

      it 'retries the message' do
        post "/api/v1/accounts/#{account.id}/conversations/#{message.conversation.display_id}/messages/#{message.id}/retry",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(message.reload.status).to eq('sent')
        expect(message.reload.content_attributes['external_error']).to be_nil
      end
    end

    context 'when the message id is invalid' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: message.conversation.inbox, user: agent)
      end

      it 'returns not found error' do
        post "/api/v1/accounts/#{account.id}/conversations/#{message.conversation.display_id}/messages/99999/retry",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/conversations/:conversation_id/messages/:id' do
    let(:api_channel) { create(:channel_api, account: account) }
    let(:api_inbox) { create(:inbox, channel: api_channel, account: account) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let!(:conversation) { create(:conversation, inbox: api_inbox, account: account) }
    let!(:message) { create(:message, conversation: conversation, account: account, status: :sent) }

    context 'when unauthenticated' do
      it 'returns unauthorized' do
        patch api_v1_account_conversation_message_url(account_id: account.id, conversation_id: conversation.display_id, id: message.id)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated agent' do
      context 'when agent has non-API inbox' do
        let(:inbox) { create(:inbox, account: account) }
        let(:agent) { create(:user, account: account, role: :agent) }
        let!(:conversation) { create(:conversation, inbox: inbox, account: account) }

        before { create(:inbox_member, inbox: inbox, user: agent) }

        it 'returns forbidden' do
          patch api_v1_account_conversation_message_url(
            account_id: account.id,
            conversation_id: conversation.display_id,
            id: message.id
          ), params: { status: 'failed', external_error: 'err' }, headers: agent.create_new_auth_token, as: :json
          expect(response).to have_http_status(:forbidden)
        end
      end

      context 'when agent has API inbox' do
        before { create(:inbox_member, inbox: api_inbox, user: agent) }

        it 'uses StatusUpdateService to perform status update' do
          service = instance_double(Messages::StatusUpdateService)
          expect(Messages::StatusUpdateService).to receive(:new)
            .with(message, 'failed', 'err123')
            .and_return(service)
          expect(service).to receive(:perform)
          patch api_v1_account_conversation_message_url(
            account_id: account.id,
            conversation_id: conversation.display_id,
            id: message.id
          ), params: { status: 'failed', external_error: 'err123' }, headers: agent.create_new_auth_token, as: :json
        end

        it 'updates status to failed with external_error' do
          patch api_v1_account_conversation_message_url(
            account_id: account.id,
            conversation_id: conversation.display_id,
            id: message.id
          ), params: { status: 'failed', external_error: 'err123' }, headers: agent.create_new_auth_token, as: :json

          expect(response).to have_http_status(:success)
          expect(message.reload.status).to eq('failed')
          expect(message.reload.external_error).to eq('err123')
        end
      end

      context 'when agent edits a WhatsApp Web message' do
        let(:channel) { create(:channel_whatsapp_web, account: account) }
        let(:inbox) { create(:inbox, channel: channel, account: account) }
        let!(:conversation) { create(:conversation, inbox: inbox, account: account) }
        let!(:message) do
          create(
            :message,
            conversation: conversation,
            inbox: inbox,
            account: account,
            message_type: :outgoing,
            content: 'Original text',
            source_id: 'wa-msg-1'
          )
        end

        before { create(:inbox_member, inbox: inbox, user: agent) }

        it 'updates the local message content and marks it edited' do
          provider_response = { 'status' => 'SUCCESS' }
          allow_any_instance_of(WhatsappWeb::Providers::EvolutionService)
            .to receive(:request)
            .with(
              :post,
              "/chat/updateMessage/#{channel.instance_name}",
              body: {
                number: "#{conversation.contact_inbox.source_id}@s.whatsapp.net",
                text: 'Edited from onelink',
                key: {
                  id: 'wa-msg-1',
                  fromMe: true,
                  remoteJid: "#{conversation.contact_inbox.source_id}@s.whatsapp.net"
                }
              }
            ).and_return(provider_response)

          patch api_v1_account_conversation_message_url(
            account_id: account.id,
            conversation_id: conversation.display_id,
            id: message.id
          ), params: { content: 'Edited from onelink' }, headers: agent.create_new_auth_token, as: :json

          expect(response).to have_http_status(:success)
          expect(message.reload.content).to eq('Edited from onelink')
          expect(message.content_attributes['edited']).to eq(true)
        end
      end
    end
  end
end
