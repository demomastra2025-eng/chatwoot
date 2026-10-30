# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::OwnerFinance API', type: :request do
  let(:account) { create(:account) }
  let(:owner_user) { create(:user, account: account, role: :administrator) }
  let(:other_admin) { create(:user, account: account, role: :administrator) }

  around do |example|
    with_modified_env(
      'OWNER_FINANCE_USER_ID' => owner_user.id.to_s,
      'OWNER_FINANCE_WORKSPACE_ACCOUNT_ID' => account.id.to_s
    ) do
      example.run
    end
  end

  describe 'Strict User #6 security & impersonation isolation' do
    it 'returns 401 for unauthenticated requests' do
      get '/api/v1/owner_finance/dashboard', as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 404 Not Found for any non-owner user and hides owner_finance_enabled from their profile' do
      other_headers = other_admin.create_new_auth_token

      get '/api/v1/owner_finance/dashboard', headers: other_headers, as: :json
      expect(response).to have_http_status(:not_found)

      get '/api/v1/profile', headers: other_headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key('owner_finance_enabled')
    end

    it 'blocks SuperAdmin impersonation of the owner with 404 Not Found' do
      super_admin = create(:super_admin)
      grant = SuperAdmin::ImpersonationService.issue_grant!(
        actor: super_admin, account: account, target_user: owner_user
      )
      raw_grant = SuperAdmin::ImpersonationService.grant_for(user: owner_user, token: grant.token)
      SuperAdmin::ImpersonationService.consume_grant!(user: owner_user, token: grant.token, grant: raw_grant)
      imp_headers = owner_user.create_new_auth_token(grant.client_id)

      get '/api/v1/owner_finance/dashboard', headers: imp_headers, as: :json
      expect(response).to have_http_status(:not_found)

      get '/api/v1/profile', headers: imp_headers, as: :json
      expect(response.parsed_body).not_to have_key('owner_finance_enabled')
    end

    it 'exposes owner_finance_enabled: true to the direct owner and conforms to OpenAPI profile schema' do
      get '/api/v1/profile', headers: owner_user.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      expect(response).to conform_schema(200)
      expect(response.parsed_body['owner_finance_enabled']).to be(true)
    end
  end

  describe 'Full Owner CRUD, vendor auto-learning, and personal tombstone flow' do
    let(:owner_headers) { owner_user.create_new_auth_token }

    it 'creates accounts and contracts with auto-synced expiry deadlines' do
      post '/api/v1/owner_finance/accounts',
           params: {
             account: { name: 'ИП Veritas Consult', account_kind: 'business_bank', scope: 'business', currency: 'KZT', current_balance: 3_500_000 }
           },
           headers: owner_headers, as: :json
      expect(response).to have_http_status(:created)

      post '/api/v1/owner_finance/contracts',
           params: {
             contract: {
               client_name: 'Клиника Мирзоев', title: 'Подписка OneLink ИИ + РОП',
               status: 'active', tariff_code: 'ai_agent_rop_199k', monthly_amount: 199_000,
               currency: 'KZT', ends_on: '2026-11-05', onelink_account_id: account.id, medelement_commission_enabled: true
             }
           },
           headers: owner_headers, as: :json
      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to include('medelement_monthly_commission_kzt' => 59_700.0, 'onelink_account_name' => account.name)

      get '/api/v1/owner_finance/dashboard', params: { year: 2026, month: 10 }, headers: owner_headers, as: :json
      expect(response.parsed_body.dig('kpis', 'total_balance_kzt')).to eq(3_500_000.0)
      expect(response.parsed_body['deadlines'].size).to eq(1)
    end

    it 'imports CSV statements, learns business vendors, and destroys hidden personal purchases' do
      csv = "date,amount,currency,merchant,description\n2026-10-28,-9500.00,KZT,Zoom Video,Pro\n2026-10-29,-4200.00,KZT,Coffee Boom,Латте\n"
      Tempfile.create(['stmt', '.csv']) do |temp|
        temp.write(csv)
        temp.rewind
        uploaded = Rack::Test::UploadedFile.new(temp.path, 'text/csv', false, original_filename: 'oct.csv')
        post '/api/v1/owner_finance/statements/import', params: { file: uploaded }, headers: owner_headers
      end
      expect(response.parsed_body['queued_for_review']).to eq(2)

      zoom_tx = OwnerFinance::TransactionRecord.find_by!(merchant: 'Zoom Video')
      patch "/api/v1/owner_finance/transactions/#{zoom_tx.id}",
            params: { transaction: { review_status: 'confirmed', pnl_treatment: 'pnl', category: 'accounting_and_software' } },
            headers: owner_headers, as: :json
      expect(OwnerFinance::Counterparty.find_by(normalized_key: 'zoom video')&.default_category).to eq('accounting_and_software')

      coffee_tx = OwnerFinance::TransactionRecord.find_by!(merchant: 'Coffee Boom')
      post "/api/v1/owner_finance/transactions/#{coffee_tx.id}/hide_personal",
           params: { hide_merchant_always: true }, headers: owner_headers, as: :json
      expect(OwnerFinance::TransactionRecord.where(id: coffee_tx.id)).to be_empty
      expect(OwnerFinance::PersonalTombstone.count).to eq(1)
    end
  end
end
