require 'rails_helper'

RSpec.describe 'Company conversations API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:company) { create(:company, account: account) }

  before do
    account.enable_features!('companies')
  end

  describe 'GET /api/v1/accounts/{account.id}/companies/{company.id}/conversations' do
    it 'returns conversations for direct and deal-related company contacts' do
      direct_contact = create(:contact, account: account, company: company)
      deal_contact = create(:contact, account: account)
      deal = create(:crm_deal, account: account, company: company)
      create(:crm_deal_contact, account: account, deal: deal, contact: deal_contact)
      direct_conversation = create(:conversation, account: account, contact: direct_contact)
      deal_conversation = create(:conversation, account: account, contact: deal_contact)
      create(:conversation, account: account, contact: create(:contact, account: account))

      get "/api/v1/accounts/#{account.id}/companies/#{company.id}/conversations",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].pluck('id')).to contain_exactly(direct_conversation.display_id, deal_conversation.display_id)
    end
  end
end
