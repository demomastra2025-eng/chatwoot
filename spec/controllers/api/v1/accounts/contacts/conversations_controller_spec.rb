require 'rails_helper'

RSpec.describe '/api/v1/accounts/{account.id}/contacts/:id/conversations', type: :request do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox_1) { create(:inbox, account: account) }
  let(:inbox_2) { create(:inbox, account: account) }
  let(:contact_inbox_1) { create(:contact_inbox, contact: contact, inbox: inbox_1) }
  let(:contact_inbox_2) { create(:contact_inbox, contact: contact, inbox: inbox_2) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:unknown) { create(:user, account: account, role: nil) }

  before do
    create(:inbox_member, user: agent, inbox: inbox_1)
    InboxMember.where(user: agent, inbox: inbox_2).delete_all
    2.times.each do
      create(:conversation, account: account, inbox: inbox_1, contact: contact, contact_inbox: contact_inbox_1)
      create(:conversation, account: account, inbox: inbox_2, contact: contact, contact_inbox: contact_inbox_2)
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/contacts/:id/conversations' do
    context 'when unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when user is logged in' do
      context 'with user as administrator' do
        it 'returns conversations from all inboxes' do
          get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations", headers: admin.create_new_auth_token

          expect(response).to have_http_status(:success)
          json_response = response.parsed_body

          expect(json_response['payload'].length).to eq 4
        end

        it 'filters the selected inbox before limiting recent conversations' do
          account.conversations.where(inbox: inbox_1).find_each { |conversation| conversation.update!(last_activity_at: 2.days.ago) }
          create_list(:conversation, 20, account: account, inbox: inbox_2,
                                         contact: contact, contact_inbox: contact_inbox_2, last_activity_at: Time.current)

          get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations",
              params: { inbox_id: inbox_1.id }, headers: admin.create_new_auth_token

          expect(response).to have_http_status(:success)
          payload = response.parsed_body['payload']
          expect(payload.length).to eq 2
          expect(payload.pluck('inbox_id')).to all(eq(inbox_1.id))
        end

        it 'does not include conversations from a foreign account inbox' do
          foreign_inbox = create(:inbox)

          get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations",
              params: { inbox_id: foreign_inbox.id }, headers: admin.create_new_auth_token

          expect(response).to have_http_status(:success)
          expect(response.parsed_body['payload']).to be_empty
        end
      end

      context 'with user as agent' do
        it 'returns conversations from the inboxes which agent has access to' do
          get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations", headers: agent.create_new_auth_token

          expect(response).to have_http_status(:success)
          json_response = response.parsed_body

          expect(json_response['payload'].length).to eq 2
        end

        it 'does not bypass inbox permissions through the requested inbox filter' do
          get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations",
              params: { inbox_id: inbox_2.id }, headers: agent.create_new_auth_token

          expect(response).to have_http_status(:success)
          expect(response.parsed_body['payload']).to be_empty
        end
      end

      context 'with user as unknown role' do
        it 'returns conversations from no inboxes' do
          InboxMember.where(user: unknown).delete_all
          get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/conversations", headers: unknown.create_new_auth_token

          expect(response).to have_http_status(:success)
          json_response = response.parsed_body

          expect(json_response['payload'].length).to eq 0
        end
      end
    end
  end
end
