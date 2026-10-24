require 'rails_helper'

RSpec.describe 'Contact Label API', type: :request do
  let(:account) { create(:account) }

  describe 'GET /api/v1/accounts/{account.id}/contacts/<id>/labels' do
    let(:contact) { create(:contact, account: account) }

    before do
      contact.update_labels('label1, label2')
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get api_v1_account_contact_labels_url(account_id: account.id, contact_id: contact.id)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      it 'returns all the labels for the contact' do
        get api_v1_account_contact_labels_url(account_id: account.id, contact_id: contact.id),
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('label1')
        expect(response.body).to include('label2')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/contacts/<id>/labels' do
    let(:contact) { create(:contact, account: account) }

    before do
      contact.update_labels('label1, label2')
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post api_v1_account_contact_labels_url(account_id: account.id, contact_id: contact.id),
             params: { labels: %w[label3 label4] },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      it 'creates labels for the contact' do
        post api_v1_account_contact_labels_url(account_id: account.id, contact_id: contact.id),
             params: { labels: %w[label3 label4] },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('label3')
        expect(response.body).to include('label4')
      end
    end
  end

  describe 'the labels of a person, seen from the contact card' do
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:contact) { create(:contact, account: account) }
    let!(:first_conversation) { create(:conversation, account: account, contact: contact) }
    let!(:second_conversation) { create(:conversation, account: account, contact: contact) }
    let(:url) { api_v1_account_contact_labels_url(account_id: account.id, contact_id: contact.id) }
    let(:labels) { response.parsed_body['payload'] }

    before do
      contact.update_labels(%w[card_only shared])
      first_conversation.update_labels(%w[shared channel_one])
      second_conversation.update_labels(%w[channel_two])
    end

    it 'shows the labels of the contact and of all its conversations, the same as the dialog' do
      get url, headers: agent.create_new_auth_token, as: :json

      expect(labels).to eq(%w[card_only shared channel_one channel_two])
    end

    it 'writes an added label to the contact and to every conversation' do
      post url, params: { add: %w[vip] }, headers: agent.create_new_auth_token, as: :json

      expect(labels).to include('vip')
      expect(contact.reload.label_list).to include('vip')
      expect([first_conversation, second_conversation].map { |conversation| conversation.reload.label_list.to_a })
        .to all(include('vip'))
    end

    it 'removes a label from the contact and from every conversation, so the dialog stops showing it' do
      post url, params: { remove: %w[shared] }, headers: agent.create_new_auth_token, as: :json

      expect(labels).to eq(%w[card_only channel_one channel_two])
      expect(contact.reload.label_list).not_to include('shared')
      expect(first_conversation.reload.label_list).not_to include('shared')
    end

    it 'removes a label that only a conversation carries' do
      post url, params: { remove: %w[channel_two] }, headers: agent.create_new_auth_token, as: :json

      expect(labels).not_to include('channel_two')
      expect(second_conversation.reload.label_list).to be_empty
    end

    it 'does not drop a label that only the conversations carry when an older client sends the card labels as a whole list' do
      post url, params: { labels: %w[card_only vip] }, headers: agent.create_new_auth_token, as: :json

      expect(labels).to contain_exactly('card_only', 'vip', 'channel_one', 'channel_two')
      expect(first_conversation.reload.label_list).to include('vip', 'channel_one')
    end

    it 'still removes a card label that an older client left out of its whole list' do
      post url, params: { labels: %w[shared] }, headers: agent.create_new_auth_token, as: :json

      expect(contact.reload.label_list).to eq(%w[shared])
    end

    it 'reports the change once however many conversations the person has' do
      expect { post url, params: { add: %w[vip] }, headers: agent.create_new_auth_token, as: :json }
        .to have_enqueued_job(Conversations::ActivityMessageJob).once
    end

    context 'when the person has an open, a snoozed and a pending conversation' do
      include PersonThreadStatusHelpers

      let!(:third_conversation) { create(:conversation, account: account, contact: contact) }

      def give_statuses
        give_person_different_statuses(first_conversation, [second_conversation, 'snoozed'], [third_conversation, 'pending'])
      end

      before { give_statuses }

      it 'keeps the thread open, in the list and in the realtime update, when a label is added on the card' do
        post url, params: { add: %w[vip] }, headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(thread_status_of(first_conversation)).to eq('open')
        expect(realtime_status_of(first_conversation)).to eq('open')
      end

      it 'keeps the thread open when a label is removed on the card' do
        post url, params: { remove: %w[shared channel_two] }, headers: agent.create_new_auth_token, as: :json

        expect(labels).to eq(%w[card_only channel_one])
        expect(thread_status_of(first_conversation)).to eq('open')
        expect(realtime_status_of(first_conversation)).to eq('open')
      end
    end
  end
end
