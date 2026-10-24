require 'rails_helper'

RSpec.describe 'Conversation Label API', type: :request do
  let(:account) { create(:account) }

  describe 'GET /api/v1/accounts/{account.id}/conversations/<id>/labels' do
    let(:conversation) { create(:conversation, account: account) }

    before do
      conversation.update_labels('label1, label2')
      conversation.contact.update_labels('contact_label')
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get api_v1_account_conversation_labels_url(account_id: account.id, conversation_id: conversation.display_id)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user with access to the conversation' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, inbox: conversation.inbox, user: agent)
      end

      it 'returns all the labels for the conversation' do
        get api_v1_account_conversation_labels_url(account_id: account.id, conversation_id: conversation.display_id),
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('label1')
        expect(response.body).to include('label2')
        expect(response.body).to include('contact_label')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/<id>/labels' do
    let(:conversation) { create(:conversation, account: account) }

    before do
      conversation.update_labels('label1, label2')
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post api_v1_account_conversation_labels_url(account_id: account.id, conversation_id: conversation.display_id),
             params: { labels: %w[label3 label4] },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user with access to the conversation' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        conversation.update_labels('label1, label2')
        create(:inbox_member, inbox: conversation.inbox, user: agent)
      end

      it 'creates labels for the conversation' do
        post api_v1_account_conversation_labels_url(account_id: account.id, conversation_id: conversation.display_id),
             params: { labels: %w[label3 label4] },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('label3')
        expect(response.body).to include('label4')
        expect(conversation.reload.label_list).to contain_exactly('label3', 'label4')
        expect(conversation.contact.reload.label_list).to contain_exactly('label3', 'label4')
      end

      context 'when the person has other channels and labels on the contact card' do
        let(:other_conversation) { create(:conversation, account: account, contact: conversation.contact) }
        let(:url) { api_v1_account_conversation_labels_url(account_id: account.id, conversation_id: conversation.display_id) }

        before do
          other_conversation.update_labels(%w[other_channel])
          conversation.contact.update_labels(%w[card_only])
        end

        it 'adds a label to the contact and to every channel as a change' do
          post url, params: { add: %w[label3] }, headers: agent.create_new_auth_token, as: :json

          expect(response.parsed_body['payload']).to contain_exactly('label1', 'label2', 'label3', 'card_only')
          expect(other_conversation.reload.label_list).to include('label3')
          expect(conversation.contact.reload.label_list).to include('label3')
        end

        it 'removes a label from every channel and from the contact' do
          post url, params: { remove: %w[other_channel card_only] }, headers: agent.create_new_auth_token, as: :json

          expect(other_conversation.reload.label_list).to be_empty
          expect(conversation.contact.reload.label_list).to be_empty
        end

        it 'does not drop a label that lives only on the contact card when a stale whole list arrives' do
          post url, params: { labels: %w[label1 label3] }, headers: agent.create_new_auth_token, as: :json

          expect(conversation.contact.reload.label_list).to contain_exactly('card_only', 'label1', 'label3')
          expect(conversation.reload.label_list).to contain_exactly('label1', 'label3')
          expect(response.parsed_body['payload']).to contain_exactly('label1', 'label3', 'card_only')
        end
      end
    end
  end
end
