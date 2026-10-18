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
        Audited::Audit.create!(auditable: account, associated: account, action: 'apply_plan', audited_changes: { 'plan' => 'base' },
                               comment: 'super_admin')

        get '/super_admin/audits'
        page = Nokogiri::HTML(response.body)

        row = page.css('tbody tr').find { |tr| tr.text.include?("##{account.id}") }
        expect(row.text).to include('Аккаунт', 'Применение тарифа')
        expect(page.at_css('[data-testid="audits-total"]').text).to include('Всего записей')
        expect(response.body).not_to include('translation missing')
      end

      it 'keeps the chosen filters in the form' do
        Audited::Audit.create!(auditable: account, associated: account, action: 'apply_plan', audited_changes: {}, comment: 'super_admin')
        get '/super_admin/audits', params: { auditable_type: 'Account', audit_action: 'update', account_id: account.id }
        page = Nokogiri::HTML(response.body)

        expect(page.at_css('select#auditable_type option[selected]')['value']).to eq('Account')
        expect(page.at_css('select#audit_action option[selected]')['value']).to eq('update')
        expect(page.at_css('input#account_id')['value']).to eq(account.id.to_s)
      end

      it 'names a partner access as the actor, never as a person' do
        partner = create(:platform_app, name: 'Портал клиник')
        Audited::Audit.create!(auditable: account, associated: account, action: 'partner_create_account', audited_changes: {},
                               user: partner, comment: 'platform_app')

        get '/super_admin/audits'

        row = Nokogiri::HTML(response.body).css('tbody tr').find { |tr| tr.text.include?("##{account.id}") }
        expect(row.text).to include('Партнёр: Портал клиник', 'Партнёр: создание аккаунта')
        expect(response.body).not_to include('translation missing')
      end

      it 'names an actor whose partner access was deleted by its number' do
        Audited::Audit.create!(auditable: account, associated: account, action: 'partner_update_account', audited_changes: {},
                               user_id: 987_654, user_type: 'PlatformApp', comment: 'platform_app')

        get '/super_admin/audits'

        expect(response.body).to include('Партнёр: №987654')
      end

      it 'shows an entry that has no object (an unknown e-mail at the sign-in) with the typed e-mail and a dash' do
        Audited::Audit.create!(auditable: nil, action: 'super_admin_login_failed', audited_changes: { 'reason' => 'unknown_email' },
                               user: 'nobody@example.com', comment: 'system')

        get '/super_admin/audits'

        row = Nokogiri::HTML(response.body).css('tbody tr').find { |tr| tr.text.include?('nobody@example.com') }
        expect(row.text).to include('Неудачная попытка входа в супер-админку')
        expect(row.text).not_to include('{', 'account')
      end

      it 'offers the actions of the security side in the filter, with Russian names' do
        get '/super_admin/audits'

        options = Nokogiri::HTML(response.body).css('select#audit_action option').to_h { |option| [option['value'], option.text.squish] }
        expect(options).to include('super_admin_login' => 'Вход в супер-админку', 'reissue_token' => 'Перевыпуск токена партнёра',
                                   'schedule_deletion' => 'Удаление аккаунта назначено', 'partner_user_token' => 'Партнёр: токен пользователя')
        expect(SuperAdmin::AuditsController::SECURITY_ACTIONS - options.keys).to be_empty
      end

      it 'has no page for a single entry: the route had no template and nothing linked to it' do
        expect { Rails.application.routes.recognize_path('/super_admin/audits/1', method: 'GET') }.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
