# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Super Admin Audits', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account) }

  # The limits of the entries on the page, one line each
  def limit_lines = Nokogiri::HTML(response.body).css('[data-testid="audit-limit-lines"] li').map { |node| node.text.squish }

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

      it 'shows the limits a plan wrote in words, never as the number that stands for no limit, and keeps what is stored', :aggregate_failures do
        limits = { 'conversations' => { 'from' => nil, 'to' => ChatwootApp.max_limit }, 'agents' => { 'from' => 0, 'to' => 5 },
                   'storage_bytes' => { 'from' => 1.gigabyte, 'to' => ChatwootApp.max_limit * 1.gigabyte } }
        audit = Audited::Audit.create!(auditable: account, associated: account, action: 'apply_plan', audited_changes: { 'limits' => limits },
                                       comment: 'super_admin')

        get '/super_admin/audits'

        expect(limit_lines).to eq(['Операторы: 0 → 5', 'Диалоги за 30 дней: не задан → Без ограничений', 'Хранилище: 1 ГБ → Без ограничений'])
        expect(limit_lines.join).not_to include(ChatwootApp.max_limit.to_s)
        expect(audit.reload.audited_changes['limits']['conversations']['to']).to eq(ChatwootApp.max_limit)
      end

      it 'tells the limits of «Обновить лимиты по тарифу» one line each, in words, and keeps what is stored', :aggregate_failures do
        limits = { 'emails' => { 'from' => nil, 'to' => 100 }, 'captain_responses' => { 'from' => 500, 'to' => ChatwootApp.max_limit * 1_000 },
                   'agents' => { 'from' => 10, 'to' => 12 } }
        audit = Audited::Audit.create!(auditable: account, associated: account, action: 'sync_plan_limits', comment: 'super_admin',
                                       audited_changes: { 'limits' => limits, 'bulk' => true })

        get '/super_admin/audits'
        details = Nokogiri::HTML(response.body).css('pre').map(&:text).join

        expect(limit_lines).to eq(['Операторы: 10 → 12', 'Ответы ИИ: 500 → Без ограничений', 'Письма в день: не задан → 100'])
        expect(details).to include('"bulk": true')
        expect(details).not_to include('"limits"', (ChatwootApp.max_limit * 1_000).to_s)
        expect(Nokogiri::HTML(response.body).text).to include('Обновление лимитов по тарифу')
        expect(audit.reload.audited_changes['limits']['captain_responses']['to']).to eq(ChatwootApp.max_limit * 1_000)
      end

      it 'shows the limits of a plan one line each, and the rest of the entry as it was', :aggregate_failures do
        Audited::Audit.create!(auditable: account, associated: account, action: 'apply_plan', comment: 'super_admin',
                               audited_changes: { 'before' => { 'plan' => nil }, 'after' => { 'plan' => 'base' },
                                                  'limits' => { 'agents' => { 'from' => 0, 'to' => 5 } } })

        get '/super_admin/audits'
        details = Nokogiri::HTML(response.body).css('pre').map(&:text).join

        expect(limit_lines).to eq(['Операторы: 0 → 5'])
        expect(details).to include('"before"', '"after"', '"plan": "base"')
        expect(details).not_to include('"limits"')
      end

      it 'shows the limits of an ordinary save in words, and leaves out the lists the limits keep for themselves', :aggregate_failures do
        max = ChatwootApp.max_limit
        before = { 'conversations' => max, 'storage_bytes' => 50.gigabytes, 'agents' => 3 }
        after = { 'conversations' => max, 'storage_bytes' => max * 1.gigabyte, 'captain_tokens' => max * 1_000_000 }
        lists = { 'limit_overrides' => { 'agents' => 3 }, 'limit_plan_numbers' => { 'conversations' => max } }
        attributes = [{ 'crm_id' => '1' }, { 'crm_id' => '1' }.merge(lists)]
        audit = Audited::Audit.create!(auditable: account, associated: account, action: 'update', comment: 'super_admin',
                                       audited_changes: { 'limits' => [before, after], 'custom_attributes' => attributes, 'name' => %w[Old New] })

        get '/super_admin/audits'
        details = Nokogiri::HTML(response.body).css('pre').map(&:text).join

        expect(details).to include('"conversations": "Без ограничений"', '"storage_bytes": "50 ГБ"', '"storage_bytes": "Без ограничений"',
                                   '"captain_tokens": "Без ограничений"', '"agents": "3"', '"name"')
        expect(details).not_to include(max.to_s, (max * 1.gigabyte).to_s, 'limit_overrides', 'limit_plan_numbers')
        expect(audit.reload.audited_changes['limits'].last['conversations']).to eq(max)
      end

      it 'shows the limits a partner wrote in words as well' do
        Audited::Audit.create!(auditable: account, associated: account, action: 'partner_create_account', comment: 'platform_app',
                               audited_changes: { 'limits' => { 'agents' => 5, 'conversations' => ChatwootApp.max_limit } })

        get '/super_admin/audits'
        details = Nokogiri::HTML(response.body).css('pre').map(&:text).join

        expect(details).to include('"agents": "5"', '"conversations": "Без ограничений"')
      end

      it 'shows the words of a change of the limits as they were written, one line per limit', :aggregate_failures do
        Audited::Audit.create!(auditable: account, associated: account, action: 'update_limits', comment: 'super_admin',
                               audited_changes: { 'limits' => { 'agents' => { 'label' => 'Операторы', 'from' => 'как в тарифе (без ограничений)',
                                                                              'to' => 'своё число (5 операторов)' } } })

        get '/super_admin/audits'

        expect(limit_lines).to eq(['Операторы: как в тарифе (без ограничений) → своё число (5 операторов)'])
        expect(Nokogiri::HTML(response.body).css('pre')).to be_empty # nothing but the limits: no JSON to read
      end

      it 'puts the limits of a change in the order of the screens, whatever order the database gave them', :aggregate_failures do
        # a jsonb column keeps no order: the shortest key comes first
        changes = { 'emails' => ['Письма в день', 'как в тарифе (100 писем в день)', 'своё число (50 писем в день)'],
                    'agents' => ['Операторы', 'своё число (5 операторов)', 'без ограничений'],
                    'storage_bytes' => ['Хранилище', 'как в тарифе (без ограничений)', 'своё число (0,5 ГБ)'] }
        limits = changes.transform_values { |label, from, to| { 'to' => to, 'from' => from, 'label' => label } }
        Audited::Audit.create!(auditable: account, associated: account, action: 'update_limits', comment: 'super_admin',
                               audited_changes: { 'limits' => limits })

        get '/super_admin/audits'

        expect(limit_lines).to eq(['Операторы: своё число (5 операторов) → без ограничений',
                                   'Хранилище: как в тарифе (без ограничений) → своё число (0,5 ГБ)',
                                   'Письма в день: как в тарифе (100 писем в день) → своё число (50 писем в день)'])
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
        partner = create(:platform_app)
        Audited::Audit.create!(auditable: account, associated: account, action: 'partner_update_account', audited_changes: {},
                               user: partner, comment: 'platform_app')
        PlatformApp.where(id: partner.id).delete_all

        get '/super_admin/audits'

        expect(response.body).to include("Партнёр: №#{partner.id}")
      end

      it 'never shows the secret of a channel stored in an older entry of an inbox', :aggregate_failures do
        inbox = create(:inbox, account: account)
        Audited::Audit.create!(auditable: inbox, associated: account, action: 'update',
                               audited_changes: { 'string_session' => [nil, 'stored-telethon-session'], 'name' => %w[A B] })

        get '/super_admin/audits'

        row = Nokogiri::HTML(response.body).css('tbody tr').find { |tr| tr.text.include?('[FILTERED]') }
        expect(row.text).to include("##{inbox.id}", 'Изменения (полей: 2)')
        expect(response.body).not_to include('stored-telethon-session')
      end

      it 'shows an entry that has no object (an unknown e-mail at the sign-in) with the typed e-mail and a dash' do
        Audited::Audit.create!(auditable: nil, action: 'super_admin_login_failed', audited_changes: { 'reason' => 'unknown_email' },
                               user: 'nobody@example.com', comment: 'system')

        get '/super_admin/audits'

        row = Nokogiri::HTML(response.body).css('tbody tr').find { |tr| tr.text.include?('nobody@example.com') }
        expect(row.text).to include('Неудачная попытка входа в супер-админку')
        expect(row.css('td')[2].text.squish).to eq('—')
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
