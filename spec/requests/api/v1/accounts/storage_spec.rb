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

  describe 'POST /api/v1/accounts/{account.id}/storage/preview_cleanup' do
    context 'when administrator' do
      it 'returns preview summary of files to be cleaned' do
        post "/api/v1/accounts/#{account.id}/storage/preview_cleanup",
             params: { file_type: 'all', older_than_months: 6 },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to include('total_count', 'total_bytes', 'samples', 'retention_days')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/storage/move_to_trash' do
    context 'when administrator' do
      it 'moves files matching criteria to trash' do
        post "/api/v1/accounts/#{account.id}/storage/move_to_trash",
             params: { file_type: 'all', older_than_months: 6 },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to include('success', 'moved_count', 'freed_bytes', 'expires_at')
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/storage/trash' do
    context 'when administrator' do
      it 'lists files in trash' do
        get "/api/v1/accounts/#{account.id}/storage/trash",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to include('total_count', 'total_bytes', 'items')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/storage/restore_trash' do
    context 'when administrator' do
      it 'restores items from trash' do
        post "/api/v1/accounts/#{account.id}/storage/restore_trash",
             params: { restore_all: true },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to include('success', 'restored_count')
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/storage/empty_trash' do
    context 'when administrator' do
      it 'empties trash' do
        delete "/api/v1/accounts/#{account.id}/storage/empty_trash",
               headers: admin.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        json = response.parsed_body
        expect(json).to include('success', 'purged_count')
      end
    end
  end
end
