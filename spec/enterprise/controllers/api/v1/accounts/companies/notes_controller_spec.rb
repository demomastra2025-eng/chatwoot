require 'rails_helper'

RSpec.describe 'Company notes API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:company) { create(:company, account: account) }

  before do
    account.enable_features!('companies')
  end

  describe 'GET /api/v1/accounts/{account.id}/companies/{company.id}/notes' do
    it 'returns recent notes for direct company contacts with contact payload' do
      contact = create(:contact, account: account, company: company)
      note = create(:note, account: account, contact: contact, user: admin, content: 'Company note')
      create(:note, account: account, contact: create(:contact, account: account), content: 'Other note')

      get "/api/v1/accounts/#{account.id}/companies/#{company.id}/notes",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].pluck('id')).to eq([note.id])
      expect(response.parsed_body.dig('payload', 0, 'contact', 'id')).to eq(contact.id)
    end

    it 'returns notes for deal-related company contacts' do
      deal_contact = create(:contact, account: account, company_id: nil)
      deal = create(:crm_deal, account: account, company: company)
      create(:crm_deal_contact, account: account, deal: deal, contact: deal_contact)
      note = create(:note, account: account, contact: deal_contact, user: admin, content: 'Deal contact note')

      get "/api/v1/accounts/#{account.id}/companies/#{company.id}/notes",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].pluck('id')).to eq([note.id])
      expect(response.parsed_body.dig('payload', 0, 'contact', 'id')).to eq(deal_contact.id)
    end
  end
end
