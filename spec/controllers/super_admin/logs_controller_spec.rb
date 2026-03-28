require 'rails_helper'

RSpec.describe 'Super Admin Logs', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/logs' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/logs'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      it 'shows the logs page' do
        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/logs'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Logs')
        expect(response.body).to include('/monitoring/grafana/d/crafty-production-logs/crafty-production-logs')
      end
    end
  end
end
