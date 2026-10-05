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
        expect(response.body).to include('Agent Dashboard')
        expect(response.body).to include('href="/app"')
      end

      it 'does not render a hard-coded DEV badge or release SHA' do
        sign_in(super_admin, scope: :super_admin)

        get '/super_admin/'

        expect(response).to have_http_status(:success)
        expect(response.body).not_to include('93611c27')
        expect(response.body).not_to match(/>\s*DEV\s*</)
        expect(response.body).to include('data-testid="environment-badge"')
        expect(response.body).to include("#{Rails.env.upcase}</span>")
      end
    end
  end
end
