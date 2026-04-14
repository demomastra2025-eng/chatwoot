require 'rails_helper'

RSpec.describe 'Super Admin Dashboard', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      it 'renders the dashboard navigation without helper errors' do
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Super Admin Console')
        expect(response.body).to include('Dashboard')
      end
    end
  end
end
