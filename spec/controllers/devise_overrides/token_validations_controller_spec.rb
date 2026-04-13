require 'rails_helper'

RSpec.describe DeviseOverrides::TokenValidationsController, type: :controller do
  include Devise::Test::ControllerHelpers

  before do
    request.env['devise.mapping'] = Devise.mappings[:user]
  end

  describe 'GET #validate_token' do
    let(:user) { create(:user) }

    it 'validates the active auth client' do
      token = user.create_token
      user.save!
      user.activate_auth_client!(token.client)

      request.headers.merge!(user.build_auth_headers(token.token, token.client))
      get :validate_token

      expect(response).to have_http_status(:success)
    end

    it 'rejects replaced sessions with a dedicated error code' do
      stale_token = user.create_token
      user.save!
      user.activate_auth_client!(stale_token.client)

      fresh_token = user.create_token
      user.save!
      user.activate_auth_client!(fresh_token.client)

      request.headers.merge!(
        user.build_auth_headers(stale_token.token, stale_token.client)
      )
      get :validate_token

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body['code']).to eq('session_replaced')
    end
  end
end
