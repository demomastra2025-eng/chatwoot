require 'rails_helper'

# Every box where a person types a phone number or a name to find a contact must find the same contact.
RSpec.describe 'Contact search entry points', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let!(:contact) { create(:contact, account: account, name: 'Семён Киселёв', email: 'semen@test.com', phone_number: '+77072817060') }
  let(:phone_formats) do
    ['87072817060', '+77072817060', '7 707 281 70 60', '+7 (707) 281-70-60', '707 281 70 60', '8-707-281-70-60', "+7\u00A0707\u00A0281\u00A070\u00A060",
     "\u200E+7 707 281 70 60\u200F"]
  end

  before do
    create(:contact, account: account, name: 'Другой', email: 'other@test.com', phone_number: '+77011234567')
    create(:contact, account: create(:account), name: 'Семён Киселёв', email: 'foreign@test.com', phone_number: '+77072817060')
  end

  def returned_ids
    payload = response.parsed_body['payload']
    payload = payload['contacts'] if payload.is_a?(Hash)
    payload.map { |item| item['id'] }
  end

  describe 'GET /api/v1/accounts/:id/contacts/search' do
    def search(text)
      get "/api/v1/accounts/#{account.id}/contacts/search", params: { q: text }, headers: headers, as: :json
    end

    it 'finds the contact by a phone number in any format' do
      aggregate_failures do
        phone_formats.each do |text|
          search(text)

          expect(response).to have_http_status(:success), "expected #{text.inspect} to be accepted"
          expect(returned_ids).to eq([contact.id]), "expected #{text.inspect} to find the contact"
        end
      end
    end

    it 'finds the contact by a name with е and ё interchanged' do
      search('семен киселев')

      expect(returned_ids).to eq([contact.id])
    end

    it 'answers a NUL byte in the query like the same query without it, not with HTTP 500' do
      search("Семён\u0000")

      expect(response).to have_http_status(:success)
      expect(returned_ids).to eq([contact.id])
    end

    it 'answers a query with an invalid byte sequence with a plain 400, not a server error' do
      get "/api/v1/accounts/#{account.id}/contacts/search?q=%D0%A1%FF%D0%B5%D0%BC", headers: headers

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'GET /api/v1/accounts/:id/search/contacts (the global search)' do
    it 'finds the contact by a phone number in any format and survives a NUL byte' do
      aggregate_failures do
        phone_formats.each do |text|
          get "/api/v1/accounts/#{account.id}/search/contacts", params: { q: text }, headers: headers, as: :json

          expect(response).to have_http_status(:success)
          expect(returned_ids).to eq([contact.id]), "expected #{text.inspect} to find the contact"
        end

        get "/api/v1/accounts/#{account.id}/search/contacts", params: { q: "Семён\u0000" }, headers: headers, as: :json
        expect(response).to have_http_status(:success)
        expect(returned_ids).to eq([contact.id])
      end
    end
  end

  describe 'GET /api/v1/accounts/:id/scheduling/contacts (the scheduling contact picker)' do
    before { account.enable_features!('scheduling', 'scheduling_finance') }

    it 'finds the contact by a phone number in any format, by name with е/ё and survives a NUL byte' do
      aggregate_failures do
        (phone_formats + ['семен киселев', "Семён\u0000"]).each do |text|
          get "/api/v1/accounts/#{account.id}/scheduling/contacts", params: { search: text }, headers: headers, as: :json

          expect(response).to have_http_status(:success)
          expect(returned_ids).to eq([contact.id]), "expected #{text.inspect} to find the contact"
        end
      end
    end
  end

  describe 'GET /api/v1/accounts/:id/companies/:company_id/contacts/search (the company contact picker)' do
    let(:company) { create(:company, account: account) }

    before { account.enable_features!('companies') }

    it 'finds the contact by a phone number in any format, by name with е/ё and survives a NUL byte' do
      aggregate_failures do
        (phone_formats + ['семен киселев', "Семён\u0000"]).each do |text|
          get "/api/v1/accounts/#{account.id}/companies/#{company.id}/contacts/search", params: { q: text }, headers: headers, as: :json

          expect(response).to have_http_status(:success)
          expect(returned_ids).to eq([contact.id]), "expected #{text.inspect} to find the contact"
        end
      end
    end
  end
end
