require 'rails_helper'

RSpec.describe 'Platform Accounts API', type: :request do
  let!(:account) { create(:account) }

  describe 'POST /platform/api/v1/accounts' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        post '/platform/api/v1/accounts'
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        post '/platform/api/v1/accounts', params: { name: 'Test Account' },
                                          headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'creates an account when and its permissible relationship' do
        post '/platform/api/v1/accounts', params: { name: 'Test Account' },
                                          headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Test Account')
        expect(platform_app.platform_app_permissibles.first.permissible.name).to eq('Test Account')
      end

      it 'creates an account with locale' do
        InstallationConfig.where(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS').first_or_create!(value: [{ 'name' => 'agent_management',
                                                                                                    'enabled' => true }])
        post '/platform/api/v1/accounts', params: { name: 'Test Account', locale: 'es' },
                                          headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)

        json_response = response.parsed_body
        expect(json_response['name']).to eq('Test Account')
        expect(json_response['locale']).to eq('es')
        expect(json_response['features']['agent_management']).to be(true)
      end

      it 'creates an account with feature flags' do
        InstallationConfig.where(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS').first_or_create!(value: [{ 'name' => 'inbox_management',
                                                                                                    'enabled' => true },
                                                                                                  { 'name' => 'disable_branding',
                                                                                                    'enabled' => true },
                                                                                                  { 'name' => 'help_center',
                                                                                                    'enabled' => false }])

        post '/platform/api/v1/accounts', params: { name: 'Test Account', features: {
          ip_lookup: true,
          help_center: true,
          disable_branding: false
        } }, headers: { api_access_token: platform_app.access_token.token }, as: :json

        json_response = response.parsed_body
        created_account = Account.find(json_response['id'])
        # the base plan is applied first, the features the caller sends are applied on top of it
        expect(created_account.enabled_features.keys).to include('inbox_management', 'ip_lookup', 'help_center')
        expect(created_account.enabled_features.keys).not_to include('disable_branding')
        expect(json_response['name']).to include('Test Account')
        expect(json_response['features'].keys).to include('inbox_management', 'ip_lookup', 'help_center')
        expect(json_response['features'].keys).not_to include('disable_branding')
      end

      it 'creates an account with limits settings' do
        post '/platform/api/v1/accounts', params: { name: 'Test Account', limits: { agents: 5, inboxes: 10 } },
                                          headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Test Account')
        expect(response.body).to include('5')
        expect(response.body).to include('10')
      end

      describe 'the plan of a new account' do
        let(:headers) { { api_access_token: platform_app.access_token.token } }
        let(:plans) { Accounts::Plans }

        def create_account(params)
          post '/platform/api/v1/accounts', params: { name: 'Planned Account' }.merge(params), headers: headers, as: :json
          Account.find(response.parsed_body['id'])
        end

        it 'applies the base plan to a new account' do
          created = create_account({})

          expect(created.custom_attributes).to include('plan' => 'base', 'plan_modules' => [], 'plan_version' => plans.version)
          expect(created.enabled_features.keys).to include(*plans.base_features, *plans.locked_on)
          expect(created.enabled_features.keys).not_to include(*plans.never_enabled, *plans.module_features('ai_agents'))
          expect(created.limits).to include('conversations' => ChatwootApp.max_limit, 'non_web_inboxes' => ChatwootApp.max_limit)
        end

        it 'lets the limits and features the caller sends win over the plan' do
          created = create_account(limits: { conversations: 50, agents: 3 }, features: { campaigns: true, crm: false })

          expect(created.limits).to include('conversations' => 50, 'agents' => 3, 'non_web_inboxes' => ChatwootApp.max_limit)
          expect(created.feature_enabled?('campaigns')).to be(true)
          expect(created.feature_enabled?('crm')).to be(false)
        end

        it 'writes one system entry in the audit log' do
          created = create_account({})

          expect(Audited::Audit.where(auditable_id: created.id, action: 'apply_plan').last).to have_attributes(user_id: nil, comment: 'system')
        end

        it 'creates no account when the plan cannot be applied' do
          allow_any_instance_of(Accounts::ApplyPlan).to receive(:call).and_raise(StandardError, 'boom') # rubocop:disable RSpec/AnyInstance

          expect do
            post '/platform/api/v1/accounts', params: { name: 'Planned Account' }, headers: headers, as: :json
          end.not_to change(Account, :count)
        end
      end
    end
  end

  describe 'GET /platform/api/v1/accounts' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        get '/platform/api/v1/accounts'
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        get '/platform/api/v1/accounts', headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }
      let!(:account1) { create(:account, name: 'Account A') }
      let!(:account2) { create(:account, name: 'Account B') }

      before do
        create(:platform_app_permissible, platform_app: platform_app, permissible: account1)
        create(:platform_app_permissible, platform_app: platform_app, permissible: account2)
      end

      it 'returns all permissible accounts' do
        get '/platform/api/v1/accounts', headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response.size).to eq(2)
        expect(json_response.map { |acc| acc['name'] }).to include('Account A', 'Account B')
      end
    end
  end

  describe 'GET /platform/api/v1/accounts/{account_id}' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        get "/platform/api/v1/accounts/#{account.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        get "/platform/api/v1/accounts/#{account.id}", headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'returns unauthorized when its not a permissible object' do
        get "/platform/api/v1/accounts/#{account.id}", headers: { api_access_token: platform_app.access_token.token }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'shows an account when its permissible object' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: account)

        get "/platform/api/v1/accounts/#{account.id}",
            headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(response.body).to include(account.name)
      end
    end
  end

  describe 'PATCH /platform/api/v1/accounts/{account_id}' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        patch "/platform/api/v1/accounts/#{account.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        patch "/platform/api/v1/accounts/#{account.id}", params: { name: 'Test Account' },
                                                         headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'returns unauthorized when its not a permissible object' do
        patch "/platform/api/v1/accounts/#{account.id}", params: { name: 'Test Account' },
                                                         headers: { api_access_token: platform_app.access_token.token }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'updates an account when its permissible object' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: account)
        account.enable_features!('inbox_management', 'channel_facebook')

        patch "/platform/api/v1/accounts/#{account.id}", params: {
          name: 'Test Account',
          features: {
            ip_lookup: true,
            help_center: true,
            channel_facebook: false
          },
          limits: { agents: 5, inboxes: 10 }
        }, headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        account.reload
        expect(account.name).to eq('Test Account')
        expect(account.enabled_features.keys).to match_array(%w[inbox_management ip_lookup help_center])
        expect(account.enabled_features['channel_facebook']).to be_nil
        expect(account.limits['agents']).to eq(5)
        expect(account.limits['inboxes']).to eq(10)
      end
    end
  end

  describe 'DELETE /platform/api/v1/accounts/{account_id}' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        delete "/platform/api/v1/accounts/#{account.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        delete "/platform/api/v1/accounts/#{account.id}", headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'returns unauthorized when its not a permissible object' do
        delete "/platform/api/v1/accounts/#{account.id}", headers: { api_access_token: platform_app.access_token.token }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'destroys the object' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: account)
        expect(DeleteObjectJob).to receive(:perform_later).with(account).once
        delete "/platform/api/v1/accounts/#{account.id}",
               headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
      end
    end
  end
end
