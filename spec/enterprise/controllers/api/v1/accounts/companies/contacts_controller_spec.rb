require 'rails_helper'

RSpec.describe 'Company contacts API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:company) { create(:company, account: account) }

  describe 'GET /api/v1/accounts/{account.id}/companies/{company.id}/contacts' do
    it 'returns direct and deal-related contacts for a company' do
      direct_contact = create(:contact, account: account, company: company, name: 'Direct Contact')
      deal_contact = create(:contact, account: account, name: 'Deal Contact')
      deal = create(:crm_deal, account: account, company: company)
      create(:crm_deal_contact, account: account, deal: deal, contact: deal_contact)

      get "/api/v1/accounts/#{account.id}/companies/#{company.id}/contacts",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].pluck('id')).to contain_exactly(direct_contact.id, deal_contact.id)
    end

    it 'does not leak contacts from another account' do
      other_account = create(:account)
      other_company = create(:company, account: other_account)
      create(:contact, account: other_account, company: other_company)

      get "/api/v1/accounts/#{account.id}/companies/#{company.id}/contacts",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload']).to be_empty
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/companies/{company.id}/contacts/search' do
    it 'returns available account contacts matching the query' do
      create(:contact, account: account, company: company, name: 'Already Linked')
      available_contact = create(:contact, account: account, name: 'Alice Buyer', email: 'alice@example.com')
      create(:contact, account: create(:account), name: 'Alice External')

      get "/api/v1/accounts/#{account.id}/companies/#{company.id}/contacts/search",
          params: { q: 'alice' },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload'].pluck('id')).to eq([available_contact.id])
    end

    it 'requires a query' do
      get "/api/v1/accounts/#{account.id}/companies/#{company.id}/contacts/search",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/companies/{company.id}/contacts' do
    it 'assigns an account contact to the company and records activity' do
      contact = create(:contact, account: account, company_id: nil, last_activity_at: 2.hours.ago)

      post "/api/v1/accounts/#{account.id}/companies/#{company.id}/contacts",
           params: { contact_id: contact.id },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(contact.reload.company).to eq(company)
      expect(company.reload.last_activity_at.to_i).to eq(contact.last_activity_at.to_i)
    end

    it 'does not assign a contact from another account' do
      other_contact = create(:contact, account: create(:account), company_id: nil)

      post "/api/v1/accounts/#{account.id}/companies/#{company.id}/contacts",
           params: { contact_id: other_contact.id },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:not_found)
      expect(other_contact.reload.company_id).to be_nil
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/companies/{company.id}/contacts/{id}' do
    it 'removes a direct company contact' do
      contact = create(:contact, account: account, company: company)

      delete "/api/v1/accounts/#{account.id}/companies/#{company.id}/contacts/#{contact.id}",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:ok)
      expect(contact.reload.company_id).to be_nil
    end

    it 'does not remove a deal-only related contact as direct membership' do
      contact = create(:contact, account: account, company_id: nil)
      deal = create(:crm_deal, account: account, company: company)
      create(:crm_deal_contact, account: account, deal: deal, contact: contact)

      delete "/api/v1/accounts/#{account.id}/companies/#{company.id}/contacts/#{contact.id}",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:not_found)
      expect(contact.reload.company_id).to be_nil
    end
  end
end
