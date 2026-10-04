require 'rails_helper'

RSpec.describe 'Super Admin', type: :request do
  describe '/super_admin' do
    it 'renders the login page' do
      with_modified_env LOGRAGE_ENABLED: 'true' do
        get '/super_admin/sign_in'
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'POST /super_admin/sign_in with wrong credentials' do
    let!(:super_admin) { create(:super_admin, password: 'Password1!') }

    it 'shows a readable error without leftover interpolation placeholders' do
      post '/super_admin/sign_in', params: { super_admin: { email: super_admin.email, password: 'nope' } }

      expect(response).to redirect_to('/super_admin/sign_in')
      expect(flash[:error]).to be_present
      expect(flash[:error]).not_to include('%{')
      expect(flash[:error]).to include('email')
    end

    it 'gives the same answer for an unknown email' do
      post '/super_admin/sign_in', params: { super_admin: { email: 'nobody@example.com', password: 'nope' } }

      expect(response).to redirect_to('/super_admin/sign_in')
      expect(flash[:error]).not_to include('%{')
    end
  end
end
