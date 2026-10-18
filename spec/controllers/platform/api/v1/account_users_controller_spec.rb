require 'rails_helper'

RSpec.describe 'Platform Account Users API', type: :request do
  let!(:account) { create(:account) }

  describe 'GET /platform/api/v1/accounts/{account_id}/account_users' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        get "/platform/api/v1/accounts/#{account.id}/account_users"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }
      let!(:account_user) { create(:account_user, account: account) }

      it 'returns all the account users for the account' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: account)

        get "/platform/api/v1/accounts/#{account.id}/account_users",
            headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include(account_user.id.to_s)
      end
    end
  end

  describe 'POST /platform/api/v1/accounts/{account_id}/account_users' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        post "/platform/api/v1/accounts/#{account.id}/account_users"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'creates a new account user for the account' do
        user = create(:user)
        create(:platform_app_permissible, platform_app: platform_app, permissible: account)
        create(:platform_app_permissible, platform_app: platform_app, permissible: user)

        post "/platform/api/v1/accounts/#{account.id}/account_users",
             params: { user_id: user.id, role: 'administrator' },
             headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data['user_id']).to eq(user.id)
      end

      it 'updates the new account user for the account' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: account)
        account_user = create(:account_user, account: account, role: 'agent')
        create(:platform_app_permissible, platform_app: platform_app, permissible: account_user.user)

        post "/platform/api/v1/accounts/#{account.id}/account_users",
             params: { user_id: account_user.user_id, role: 'administrator' },
             headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data['role']).to eq('administrator')
      end
    end
  end

  describe 'DELETE /platform/api/v1/accounts/{account_id}/account_users' do
    let(:account_user) { create(:account_user, account: account, role: 'agent') }

    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        delete "/platform/api/v1/accounts/#{account.id}/account_users", params: { user_id: account_user.user_id }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'returns deletes the account user' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: account)
        create(:platform_app_permissible, platform_app: platform_app, permissible: account_user.user)

        delete "/platform/api/v1/accounts/#{account.id}/account_users", params: { user_id: account_user.user_id },
                                                                        headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        expect(account.account_users.count).to eq 0
      end

      it 'records the removal in the audit log with the partner as the actor' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: account)
        create(:platform_app_permissible, platform_app: platform_app, permissible: account_user.user)

        delete "/platform/api/v1/accounts/#{account.id}/account_users", params: { user_id: account_user.user_id },
                                                                        headers: { api_access_token: platform_app.access_token.token }, as: :json

        audit = Audited::Audit.where(auditable: account, action: 'partner_remove_account_user').last
        expect(audit).to have_attributes(user_id: platform_app.id, user_type: 'PlatformApp')
        expect(audit.audited_changes).to include('user_id' => account_user.user_id, 'role' => 'agent')
      end

      it 'does not take out a member the partner did not create' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: account)

        delete "/platform/api/v1/accounts/#{account.id}/account_users", params: { user_id: account_user.user_id },
                                                                        headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:unauthorized)
        expect(account.account_users.count).to eq 1
      end
    end
  end

  # A partner puts only the users IT created into its accounts: an operator of another customer or a super admin never
  describe 'whose users a partner may put into its account' do
    let(:platform_app) { create(:platform_app) }
    let(:headers) { { api_access_token: platform_app.access_token.token } }

    before { create(:platform_app_permissible, platform_app: platform_app, permissible: account) }

    it 'refuses a user that exists already and belongs to nobody it knows' do
      stranger = create(:user)

      expect do
        post "/platform/api/v1/accounts/#{account.id}/account_users", params: { user_id: stranger.id, role: 'administrator' },
                                                                      headers: headers, as: :json
      end.not_to change(AccountUser, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a super admin, even one that an old attachment recorded as the partner user' do
      super_admin = create(:super_admin)
      create(:platform_app_permissible, platform_app: platform_app, permissible: super_admin)

      expect do
        post "/platform/api/v1/accounts/#{account.id}/account_users", params: { user_id: super_admin.id, role: 'administrator' },
                                                                      headers: headers, as: :json
      end.not_to change(AccountUser, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a missing or unknown user id' do
      post "/platform/api/v1/accounts/#{account.id}/account_users", params: { role: 'agent' }, headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)

      post "/platform/api/v1/accounts/#{account.id}/account_users", params: { user_id: 0, role: 'agent' }, headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'records an added member and a changed role in the audit log' do
      user = create(:user)
      create(:platform_app_permissible, platform_app: platform_app, permissible: user)

      post "/platform/api/v1/accounts/#{account.id}/account_users", params: { user_id: user.id, role: 'agent' }, headers: headers, as: :json
      post "/platform/api/v1/accounts/#{account.id}/account_users", params: { user_id: user.id, role: 'administrator' }, headers: headers, as: :json

      audits = Audited::Audit.where(auditable: account, action: 'partner_set_account_user').order(:id)
      expect(audits.map(&:audited_changes)).to eq(
        [
          { 'user_id' => user.id, 'role' => 'agent', 'added' => true },
          { 'user_id' => user.id, 'role' => 'administrator', 'added' => false }
        ]
      )
      expect(audits.map(&:user_id).uniq).to eq([platform_app.id])
    end
  end
end
