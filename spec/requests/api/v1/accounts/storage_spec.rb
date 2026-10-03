# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Storage API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  describe 'GET /api/v1/accounts/{account.id}/storage' do
    context 'when unauthenticated' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/storage"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when non-admin user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/storage",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when administrator' do
      it 'returns storage overview and breakdown' do
        get "/api/v1/accounts/#{account.id}/storage",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to have_key('storage')
        expect(json['storage']).to include(
          'total_limit_bytes',
          'consumed_bytes',
          'available_bytes',
          'unlimited',
          'breakdown'
        )
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/storage/heavy_files' do
    context 'when administrator' do
      it 'returns list of heavy files' do
        get "/api/v1/accounts/#{account.id}/storage/heavy_files",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to have_key('files')
        expect(json['files']).to be_an(Array)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/storage/refresh' do
    context 'when administrator' do
      it 'refreshes storage cache and returns fresh data' do
        post "/api/v1/accounts/#{account.id}/storage/refresh",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json['success']).to be(true)
        expect(json).to have_key('storage')
      end
    end
  end
end
