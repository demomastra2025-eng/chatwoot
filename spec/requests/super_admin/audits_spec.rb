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

      it 'names the kind of object and the action in Russian' do
        Audited::Audit.create!(auditable: account, associated: account, action: 'apply_plan', audited_changes: { 'plan' => 'base' }, comment: 'super_admin')

        get '/super_admin/audits'
        page = Nokogiri::HTML(response.body)

        row = page.css('tbody tr').find { |tr| tr.text.include?("##{account.id}") }
        expect(row.text).to include('Клиника', 'Применение тарифа')
        expect(page.at_css('[data-testid="audits-total"]').text).to include('Всего записей')
        expect(response.body).not_to include('translation missing')
      end

      it 'keeps the chosen filters in the form' do
        get '/super_admin/audits', params: { auditable_type: 'Account', audit_action: 'update', account_id: account.id }
        page = Nokogiri::HTML(response.body)

        expect(page.at_css('select#auditable_type option[selected]')['value']).to eq('Account')
        expect(page.at_css('select#audit_action option[selected]')['value']).to eq('update')
        expect(page.at_css('input#account_id')['value']).to eq(account.id.to_s)
      end

      it 'has no page for a single entry: the route had no template and nothing linked to it' do
        expect { Rails.application.routes.recognize_path('/super_admin/audits/1', method: 'GET') }.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
