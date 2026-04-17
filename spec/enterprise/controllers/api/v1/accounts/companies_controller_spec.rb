require 'rails_helper'

RSpec.describe 'Companies API', type: :request do
  let(:account) { create(:account) }

  describe 'GET /api/v1/accounts/{account.id}/companies' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/companies"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let!(:company1) { create(:company, name: 'Company 1', account: account) }
      let!(:company2) { create(:company, account: account) }

      it 'returns all companies' do
        get "/api/v1/accounts/#{account.id}/companies",
            headers: admin.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload'].size).to eq(2)
        expect(response_body['payload'].map { |c| c['name'] }).to contain_exactly(company1.name, company2.name)
      end

      it 'returns companies with pagination' do
        create_list(:company, 30, account: account)

        get "/api/v1/accounts/#{account.id}/companies",
            params: { page: 1 },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload'].size).to eq(25)
        expect(response_body['meta']['total_count']).to eq(32)
        expect(response_body['meta']['page']).to eq(1)
      end

      it 'returns second page of companies' do
        create_list(:company, 30, account: account)
        get "/api/v1/accounts/#{account.id}/companies",
            params: { page: 2 },
            headers: admin.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload'].size).to eq(7)
        expect(response_body['meta']['total_count']).to eq(32)
        expect(response_body['meta']['page']).to eq(2)
      end

      it 'returns companies with contacts_count' do
        company_with_contacts = create(:company, name: 'Company With Contacts', account: account)
        create_list(:contact, 5, company: company_with_contacts, account: account)

        get "/api/v1/accounts/#{account.id}/companies",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        company_data = response_body['payload'].find { |c| c['id'] == company_with_contacts.id }
        expect(company_data['contacts_count']).to eq(5)
      end

      it 'does not return companies from other accounts' do
        other_account = create(:account)
        create(:company, name: 'Other Account Company', account: other_account)
        create(:company, name: 'My Company', account: account)
        get "/api/v1/accounts/#{account.id}/companies",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload'].size).to eq(3)
        expect(response_body['payload'].map { |c| c['name'] }).not_to include('Other Account Company')
      end

      it 'sorts companies by contacts_count in ascending order' do
        company_with_5 = create(:company, name: 'Company with 5', account: account)
        company_with_2 = create(:company, name: 'Company with 2', account: account)
        company_with_10 = create(:company, name: 'Company with 10', account: account)
        create_list(:contact, 5, company: company_with_5, account: account)
        create_list(:contact, 2, company: company_with_2, account: account)
        create_list(:contact, 10, company: company_with_10, account: account)

        get "/api/v1/accounts/#{account.id}/companies",
            params: { sort: 'contacts_count' },
            headers: admin.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        company_ids = response_body['payload'].map { |c| c['id'] }

        expect(company_ids.index(company_with_2.id)).to be < company_ids.index(company_with_5.id)
        expect(company_ids.index(company_with_5.id)).to be < company_ids.index(company_with_10.id)
      end

      it 'sorts companies by contacts_count in descending order' do
        company_with_5 = create(:company, name: 'Company with 5', account: account)
        company_with_2 = create(:company, name: 'Company with 2', account: account)
        company_with_10 = create(:company, name: 'Company with 10', account: account)
        create_list(:contact, 5, company: company_with_5, account: account)
        create_list(:contact, 2, company: company_with_2, account: account)
        create_list(:contact, 10, company: company_with_10, account: account)

        get "/api/v1/accounts/#{account.id}/companies",
            params: { sort: '-contacts_count' },
            headers: admin.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        company_ids = response_body['payload'].map { |c| c['id'] }

        expect(company_ids.index(company_with_10.id)).to be < company_ids.index(company_with_5.id)
        expect(company_ids.index(company_with_5.id)).to be < company_ids.index(company_with_2.id)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/companies/search' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/companies/search"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }

      it 'returns error when q parameter is missing' do
        get "/api/v1/accounts/#{account.id}/companies/search",
            headers: admin.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq('Specify search string with parameter q')
      end

      it 'searches companies by name' do
        create(:company, name: 'Acme Corp', domain: 'acme.com', account: account)
        create(:company, name: 'Tech Solutions', domain: 'tech.com', account: account)
        create(:company, name: 'Global Inc', domain: 'global.com', account: account)

        get "/api/v1/accounts/#{account.id}/companies/search",
            params: { q: 'tech' },
            headers: admin.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload'].size).to eq(1)
        expect(response_body['payload'].first['name']).to eq('Tech Solutions')
      end

      it 'searches companies by domain' do
        create(:company, name: 'Acme Corp', domain: 'acme.com', account: account)
        create(:company, name: 'Tech Solutions', domain: 'tech.com', account: account)
        create(:company, name: 'Global Inc', domain: 'global.com', account: account)

        get "/api/v1/accounts/#{account.id}/companies/search",
            params: { q: 'acme.com' },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload'].size).to eq(1)
        expect(response_body['payload'].first['domain']).to eq('acme.com')
      end

      it 'search is case insensitive' do
        create(:company, name: 'Acme Corp', domain: 'acme.com', account: account)
        get "/api/v1/accounts/#{account.id}/companies/search",
            params: { q: 'ACME' },
            headers: admin.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:success)
        response_body = response.parsed_body

        expect(response_body['payload'].size).to eq(1)
      end

      it 'returns empty array when no companies match search' do
        create(:company, name: 'Acme Corp', domain: 'acme.com', account: account)
        get "/api/v1/accounts/#{account.id}/companies/search",
            params: { q: 'nonexistent' },
            headers: admin.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload'].size).to eq(0)
        expect(response_body['meta']['total_count']).to eq(0)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/companies/{id}' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        company = create(:company, account: account)
        get "/api/v1/accounts/#{account.id}/companies/#{company.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:company) { create(:company, account: account) }

      it 'returns the company' do
        get "/api/v1/accounts/#{account.id}/companies/#{company.id}",
            headers: admin.create_new_auth_token,
            as: :json
        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload']['name']).to eq(company.name)
        expect(response_body['payload']['id']).to eq(company.id)
      end

      it 'returns direct contacts and deal-related contacts for the company' do
        direct_contact = create(:contact, account: account, company: company, name: 'Direct Contact')
        deal_related_contact = create(:contact, account: account, name: 'Deal Contact')
        deal = create(:crm_deal, account: account, company: company)
        create(
          :crm_deal_contact,
          account: account,
          deal: deal,
          contact: deal_related_contact,
          primary: true
        )

        get "/api/v1/accounts/#{account.id}/companies/#{company.id}",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_contacts = response.parsed_body.dig('payload', 'contacts')
        expect(response_contacts.pluck('id')).to contain_exactly(
          direct_contact.id,
          deal_related_contact.id
        )
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/companies' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/companies"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:valid_params) do
        {
          company: {
            name: 'New Company',
            domain: 'newcompany.com',
            description: 'A new company'
          }
        }
      end

      it 'creates a new company' do
        expect do
          post "/api/v1/accounts/#{account.id}/companies",
               params: valid_params,
               headers: admin.create_new_auth_token,
               as: :json
        end.to change(Company, :count).by(1)

        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload']['name']).to eq('New Company')
        expect(response_body['payload']['domain']).to eq('newcompany.com')
      end

      it 'creates multiple companies without domain' do
        auth_headers = admin.create_new_auth_token

        post "/api/v1/accounts/#{account.id}/companies",
             params: { company: { name: 'Company Without Domain 1', domain: '' } },
             headers: auth_headers,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('payload', 'domain')).to be_nil

        auth_headers = auth_headers.merge(
          response.headers
                  .slice('access-token', 'client', 'uid', 'expiry', 'token-type')
                  .compact
        )

        expect do
          post "/api/v1/accounts/#{account.id}/companies",
               params: { company: { name: 'Company Without Domain 2', domain: '' } },
               headers: auth_headers,
               as: :json
        end.to change(Company, :count).by(1)

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('payload', 'domain')).to be_nil
      end

      it 'returns error for invalid params' do
        invalid_params = { company: { name: '' } }

        post "/api/v1/accounts/#{account.id}/companies",
             params: invalid_params,
             headers: admin.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/companies/{id}' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        company = create(:company, account: account)
        patch "/api/v1/accounts/#{account.id}/companies/#{company.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:company) { create(:company, account: account) }
      let(:update_params) do
        {
          company: {
            name: 'Updated Company Name',
            domain: 'updated.com'
          }
        }
      end

      it 'updates the company' do
        patch "/api/v1/accounts/#{account.id}/companies/#{company.id}",
              params: update_params,
              headers: admin.create_new_auth_token,
              as: :json
        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload']['name']).to eq('Updated Company Name')
        expect(response_body['payload']['domain']).to eq('updated.com')
      end

      it 'normalizes blank domain to nil on update' do
        company.update!(domain: 'existing.com')

        patch "/api/v1/accounts/#{account.id}/companies/#{company.id}",
              params: { company: { domain: '   ' } },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('payload', 'domain')).to be_nil
        expect(company.reload.domain).to be_nil
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/companies/{id}' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        company = create(:company, account: account)
        delete "/api/v1/accounts/#{account.id}/companies/#{company.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated administrator' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:company) { create(:company, account: account) }

      it 'deletes the company' do
        company
        expect do
          delete "/api/v1/accounts/#{account.id}/companies/#{company.id}",
                 headers: admin.create_new_auth_token,
                 as: :json
        end.to change(Company, :count).by(-1)
        expect(response).to have_http_status(:ok)
      end

      it 'deletes a company that is referenced by crm deals' do
        deal = create(:crm_deal, account: account, company: company)

        expect do
          delete "/api/v1/accounts/#{account.id}/companies/#{company.id}",
                 headers: admin.create_new_auth_token,
                 as: :json
        end.to change(Company, :count).by(-1)

        expect(response).to have_http_status(:ok)
        expect(deal.reload.company_id).to be_nil
      end
    end

    context 'when it is a regular agent' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:company) { create(:company, account: account) }

      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/companies/#{company.id}",
               headers: agent.create_new_auth_token,
               as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
