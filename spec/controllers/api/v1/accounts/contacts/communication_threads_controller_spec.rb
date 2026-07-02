require 'rails_helper'

RSpec.describe '/api/v1/accounts/{account.id}/contacts/:id/communication_threads', type: :request do
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
    account.enable_features!('communication_threads')
    create(:inbox_member, user: agent, inbox: inbox_1)
    create(:conversation, account: account, inbox: inbox_1, contact: contact, contact_inbox: contact_inbox_1)
    create(:conversation, account: account, inbox: inbox_2, contact: contact, contact_inbox: contact_inbox_2)
  end

  describe 'GET /api/v1/accounts/{account.id}/contacts/:id/communication_threads' do
    context 'when unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/communication_threads"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when user is logged in' do
      it 'returns the contact communication thread for administrators' do
        get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/communication_threads", headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body

        expect(json_response['payload'].length).to eq 1
        expect(json_response['payload'].first['contact_id']).to eq contact.id
      end

      it 'returns forbidden when communication threads are disabled' do
        account.disable_features!('communication_threads')

        get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/communication_threads", headers: admin.create_new_auth_token

        expect(response).to have_http_status(:forbidden)
      end

      it 'returns threads with at least one conversation the agent can access' do
        get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/communication_threads", headers: agent.create_new_auth_token

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body

        expect(json_response['payload'].length).to eq 1
      end

      it 'returns no threads for users without inbox access' do
        get "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/communication_threads", headers: unknown.create_new_auth_token

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body

        expect(json_response['payload'].length).to eq 0
      end
    end
  end
end
