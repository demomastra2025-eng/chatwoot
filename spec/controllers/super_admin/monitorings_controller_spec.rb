require 'rails_helper'

RSpec.describe 'Super Admin Monitoring', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/monitoring' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/monitoring'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      it 'shows the monitoring page' do
        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/monitoring'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Monitoring')
        expect(response.body).to include('/monitoring/grafana/')
      end
    end
  end
end
