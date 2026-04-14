require 'rails_helper'

RSpec.describe 'Super Admin accounts API', type: :request do
  include ActiveJob::TestHelper

  let!(:super_admin) { create(:super_admin) }
  let!(:account) { create(:account) }

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
        expect(response.body).to include('New account')
        expect(response.body).to include(account.name)
      end
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
        expect(account.cache_keys.keys).to contain_exactly(:inbox, :label, :team)
        sign_in(super_admin, scope: :super_admin)

        now_timestamp = Time.now.utc.to_i
        post "/super_admin/accounts/#{account.id}/reset_cache"
        expect(response).to have_http_status(:redirect)
        expect(flash[:notice]).to eq('Cache keys cleared')

        range = now_timestamp..(now_timestamp + 10)
        expect(account.reload.cache_keys.values.all? { |v| range.cover?(v.to_i) }).to be(true)
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
        expect(
          account.reload.custom_attributes['limit_counter_excluded_user_ids']
        ).to eq([12, 15, 19])
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
        expect(flash[:notice]).to eq('Captain responses usage reset')
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
        expect(flash[:notice]).to eq('Captain tokens usage reset')
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
        expect(flash[:notice]).to eq('Email usage counter reset')
        expect(account.emails_sent_today).to eq(0)
      end
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
