# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Super Admin Audits', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account) }

  describe 'GET /super_admin/audits' do
    context 'when it is an unauthenticated super admin' do
      it 'redirects to login' do
        get '/super_admin/audits'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      before do
        sign_in(super_admin, scope: :super_admin)
      end

      it 'shows the audits index page' do
        get '/super_admin/audits'
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('super_admin.audits.title'))
      end

      it 'filters by auditable_type' do
        get '/super_admin/audits', params: { auditable_type: 'Account' }
        expect(response).to have_http_status(:success)
      end

      it 'filters by audit_action' do
        get '/super_admin/audits', params: { audit_action: 'update' }
        expect(response).to have_http_status(:success)
      end

      it 'filters by account_id' do
        get '/super_admin/audits', params: { account_id: account.id }
        expect(response).to have_http_status(:success)
      end
    end
  end
end
