require 'rails_helper'

RSpec.describe 'API Base', type: :request do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }

  describe 'request with api_access_token for user' do
    context 'when accessing an account scoped resource' do
      let!(:admin) { create(:user, :administrator, account: account) }
      let!(:conversation) { create(:conversation, account: account) }

      it 'sets Current attributes for the request and then returns the response' do
        # This test verifies that Current.user, Current.account, and Current.account_user
        # are properly set during request processing. We verify this indirectly:
        # - A successful response proves Current.account_user was set (required for authorization)
        # - The correct conversation data proves Current.account was set (scopes the query)
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
            headers: { api_access_token: admin.access_token.token },
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['id']).to eq(conversation.display_id)
      end
    end

    context 'when it is an invalid api_access_token' do
      it 'returns unauthorized' do
        get '/api/v1/profile',
            headers: { api_access_token: 'invalid' },
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is a valid api_access_token' do
      it 'returns current user information' do
        get '/api/v1/profile',
            headers: { api_access_token: user.access_token.token },
            as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['id']).to eq(user.id)
        expect(json_response['email']).to eq(user.email)
      end
    end
  end

  describe 'request with api_access_token for a super admin' do
    before do
      user.update!(type: 'SuperAdmin')
    end

    context 'when its a valid api_access_token' do
      it 'returns current user information' do
        get '/api/v1/profile',
            headers: { api_access_token: user.access_token.token },
            as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['id']).to eq(user.id)
        expect(json_response['email']).to eq(user.email)
      end
    end
  end

  describe 'when the account is suspended' do
      it 'returns 401 unauthorized' do
        account.update!(status: :suspended)

        post "/api/v1/accounts/#{account.id}/canned_responses",
             headers: { api_access_token: user.access_token.token },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      # this exception occured in a client instance (DoubleRender error)
      it 'will not throw exception if user does not have access to suspended account' do
        user_with_out_access = create(:user)
        account.update!(status: :suspended)

        post "/api/v1/accounts/#{account.id}/canned_responses",
             headers: { api_access_token: user_with_out_access.access_token.token },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
  end
end
