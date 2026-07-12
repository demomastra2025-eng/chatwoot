require 'rails_helper'

RSpec.describe 'Public Inbox Contact Conversation Messages API', type: :request do
  let!(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
  let!(:api_channel) { create(:channel_api, account: account) }
  let!(:contact) { create(:contact, account: account, phone_number: '+324234324', email: 'dfsadf@sfsda.com') }
  let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: api_channel.inbox) }
  let!(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: api_channel.inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
  end

  describe 'GET /public/api/v1/inboxes/{identifier}/contact/{source_id}/conversations/{conversation_id}/messages' do
    it 'return the messages for that conversation' do
      2.times.each { create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation) }

      get "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/#{conversation.display_id}/messages"

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data.length).to eq 2
    end
  end

  describe 'POST /public/api/v1/inboxes/{identifier}/contact/{source_id}/conversations/{conversation_id}/messages' do
    it 'creates a message in the conversation' do
      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/#{conversation.display_id}/messages",
           params: { content: 'hello' }

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data['content']).to eq('hello')
      expect(data['status']).to eq('sent')
    end

    it 'persists source id and reuses the same message when the request is retried' do
      path = "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/" \
             "#{conversation.display_id}/messages"
      params = { content: 'hello', source_id: 'salebot-message-1' }

      expect do
        post path, params: params
        expect(response).to have_http_status(:success)
        first_response = response.parsed_body

        post path, params: params
        expect(response).to have_http_status(:success)
        expect(response.parsed_body['id']).to eq(first_response['id'])
        expect(response.parsed_body['source_id']).to eq('salebot-message-1')
      end.to change(conversation.messages, :count).by(1)
    end

    it 'rejects a source id already used by another conversation in the inbox' do
      other_contact_inbox = create(:contact_inbox, inbox: api_channel.inbox)
      other_conversation = create(
        :conversation,
        account: api_channel.account,
        inbox: api_channel.inbox,
        contact: other_contact_inbox.contact,
        contact_inbox: other_contact_inbox
      )
      create(
        :message,
        account: api_channel.account,
        conversation: other_conversation,
        inbox: api_channel.inbox,
        source_id: 'salebot-message-2'
      )

      expect do
        post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/" \
             "#{conversation.display_id}/messages",
             params: { content: 'hello', source_id: 'salebot-message-2' }
      end.not_to change(conversation.messages, :count)

      expect(response).to have_http_status(:conflict)
    end

    it 'does not create the message' do
      content = "#{'h' * 150 * 1000}a"
      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/#{conversation.display_id}/messages",
           params: { content: content }

      expect(response).to have_http_status(:unprocessable_content)

      json_response = response.parsed_body

      expect(json_response['message']).to include(I18n.t('errors.messages.too_long', count: 150_000))
    end

    it 'creates attachment message in conversation' do
      file = fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png')
      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/#{conversation.display_id}/messages",
           params: { content: 'hello', attachments: [file] }

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data['content']).to eq('hello')

      expect(conversation.messages.last.attachments.first.file.present?).to be(true)
      expect(conversation.messages.last.attachments.first.file_type).to eq('image')
    end

    it 'returns payment required when account storage limit is reached for attachments' do
      conversation.account.update!(limits: { storage_bytes: 1000 })
      file = fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png')

      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/#{conversation.display_id}/messages",
           params: { content: 'hello', attachments: [file] }

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body['error']).to eq('Account storage limit exceeded')
    end
  end

  describe 'PATCH /public/api/v1/inboxes/{identifier}/contact/{source_id}/conversations/{conversation_id}/messages/{id}' do
    it 'updates a message in the conversation' do
      message = create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation)
      patch "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/" \
            "#{conversation.display_id}/messages/#{message.id}",
            params: { submitted_values: [{ title: 'test' }] }

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data['content_attributes']['submitted_values'].first['title']).to eq 'test'
    end

    it 'updates CSAT survey response for the conversation' do
      message = create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation, content_type: 'input_csat')
      # since csat survey is created in async job, we are mocking the creation.
      create(:csat_survey_response, conversation: conversation, message: message, rating: 4, feedback_message: 'amazing experience')

      patch "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/" \
            "#{conversation.display_id}/messages/#{message.id}",
            params: { submitted_values: { csat_survey_response: { rating: 4, feedback_message: 'amazing experience' } } },
            as: :json

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data['content_attributes']['submitted_values']['csat_survey_response']['feedback_message']).to eq 'amazing experience'
      expect(data['content_attributes']['submitted_values']['csat_survey_response']['rating']).to eq 4
    end

    it 'returns update error if CSAT message sent more than 14 days' do
      message = create(:message, account: conversation.account, inbox: conversation.inbox, conversation: conversation, content_type: 'input_csat',
                                 created_at: 15.days.ago)
      # since csat survey is created in async job, we are mocking the creation.
      create(:csat_survey_response, conversation: conversation, message: message, rating: 4, feedback_message: 'amazing experience')

      patch "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}/conversations/" \
            "#{conversation.display_id}/messages/#{message.id}",
            params: { submitted_values: { csat_survey_response: { rating: 4, feedback_message: 'amazing experience' } } },
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
