require 'rails_helper'

RSpec.describe 'Super Admin clinic forms', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:page) { Nokogiri::HTML(response.body) }

  before { sign_in(super_admin, scope: :super_admin) }

  def text(node)
    node.text.squish
  end

  def options_of(select)
    select.css('option').map { |option| [text(option), option['value']] }
  end

  describe 'the new clinic form' do
    it 'is now «Новый клиент»: the old address leads to it' do
      get '/super_admin/accounts/new'

      expect(response).to redirect_to('/super_admin/clients/new')
    end

    it 'is drawn by the old template only for a form that was posted with a problem, and points to the new page' do
      post '/super_admin/accounts', params: { account: { name: '', locale: 'ru' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(text(page.at_css('h1'))).to eq('Новый аккаунт')
      expect(page.at_css('[data-testid="moved-notice"] a')['href']).to eq('/super_admin/clients/new')
      expect(response.body).not_to include('translation missing')
    end
  end

  describe 'creating a clinic' do
    def create_clinic(name, extra = {})
      post '/super_admin/accounts', params: { account: { name: name, locale: 'ru' } }.merge(extra)
      Account.find_by(name: name)
    end

    it 'applies the base and the chosen modules and says «Аккаунт создан.»' do
      created = create_clinic('Аккаунт Север', modules: %w[quality])

      expect(response).to redirect_to("/super_admin/accounts/#{created.id}")
      expect(flash[:notice]).to eq('Аккаунт создан.')
      expect(created.custom_attributes).to include('plan' => 'base', 'plan_modules' => %w[quality])
      expect(created.feature_enabled?('sla')).to be(true)
      expect(created).not_to be_trial
    end

    it 'starts a trial on top of the plan when asked, and records it' do
      created = create_clinic('Аккаунт Юг', modules: %w[quality], start_trial: '1')

      expect(created).to be_trial_active
      expect(created.custom_attributes).to include('plan' => 'base', 'plan_modules' => %w[quality])
      expect(created.feature_enabled?('captain_integration')).to be(true)
      expect(Audited::Audit.where(auditable_id: created.id, action: 'start_trial')).to exist
      expect(Audited::Audit.where(auditable_id: created.id, action: 'apply_plan')).to exist
    end

    it 'takes the trial back without touching the plan when it ends' do
      created = create_clinic('Аккаунт Запад', modules: %w[quality], start_trial: '1')

      expect(created.expire_trial!).to be(true)

      created.reload
      expect(created.feature_enabled?('captain_integration')).to be(false)
      expect(created.feature_enabled?('sla')).to be(true)
      expect(created.feature_enabled?('crm')).to be(true)
    end

    it 'leaves the clinic able to add operators and channels when its trial ends (the limits are not locked)' do
      created = create_clinic('Аккаунт Центр', modules: %w[quality], start_trial: '1')
      created.update!(limits: created.limits.merge('agents' => 5, 'inboxes' => 8))

      expect(created.expire_trial!).to be(true)

      expect(created.reload.limits).to include('agents' => 5, 'inboxes' => 8)
      get "/super_admin/accounts/#{created.id}"
      usage = Nokogiri::HTML(response.body).at_css('[data-usage="agents"]')
      expect(usage.text.squish).to include('из 5')
      expect(usage.text).not_to include('Лимит 0')
    end

    it 'does not lock the limits of a clinic created with a trial and no limits set either' do
      created = create_clinic('Аккаунт Пустой', start_trial: '1')

      created.expire_trial!

      expect(created.reload.limits).not_to include('agents' => 0)
      expect(created.limits).not_to include('inboxes' => 0)
    end

    it 'says on the form what happens to the limits when the trial ends' do
      get '/super_admin/clients/new'

      expect(text(page.at_css('[data-testid="new-trial-block"]'))).to include('лимиты аккаунта останутся как есть')
    end

    it 'creates the account in Russian when the form sends no language, which is how the form is now' do
      post '/super_admin/accounts', params: { account: { name: 'Русский аккаунт' } }

      expect(Account.find_by!(name: 'Русский аккаунт').locale).to eq('ru')
    end

    it 'keeps the language a request names (an old form, a script); only the form without one defaults to Russian' do
      post '/super_admin/accounts', params: { account: { name: 'English clinic', locale: 'en' } }

      expect(Account.find_by!(name: 'English clinic').locale).to eq('en')
    end

    it 'ignores a trial switch that is off' do
      created = create_clinic('Аккаунт Восток', start_trial: '0')

      expect(created).not_to be_trial
    end

    it 'shows the form again with the choices kept when the name is missing' do
      expect do
        post '/super_admin/accounts', params: { account: { name: '', locale: 'ru' }, modules: %w[quality], start_trial: '1' }
      end.not_to change(Account, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(page.at_css('#error_explanation')).to be_present
      expect(page.at_css('input#plan-module-quality')['checked']).to be_present
      expect(page.at_css('input#plan-module-broadcasts')['checked']).to be_nil
      expect(page.at_css('input[name="start_trial"]')['checked']).to be_present
    end
  end

  describe 'the edit form' do
    let(:account) { create(:account, name: 'Аккаунт Алатау', limits: { 'agents' => 10, 'storage_bytes' => 50.gigabytes }) }

    before do
      Accounts::ApplyPlan.new(account: account, modules: []).call
      get "/super_admin/accounts/#{account.id}/edit"
    end

    it 'has three sections' do
      expect(response).to have_http_status(:ok)
      expect(page.css('fieldset.form-section > legend').map { |legend| text(legend) }).to eq(['Основное', 'Лимиты', 'Тонкая настройка'])
      expect(response.body).not_to include('translation missing')
    end

    it 'labels the main fields in Russian and says the language as text, with no list of languages' do
      account.update!(locale: 'ru')
      get "/super_admin/accounts/#{account.id}/edit"

      expect(text(page.at_css('label[for="account_name"]'))).to eq('Название аккаунта')
      expect(page.css('label[for="account_status"]')).to be_empty
      expect(text(page.at_css('[data-testid="account-language"]'))).to eq('Язык: русский')
      expect(page.css('[name="account[locale]"]')).to be_empty
    end

    it 'says the language an account already has, as it is, and does not change it when the form is saved' do
      account.update!(locale: 'kk')
      get "/super_admin/accounts/#{account.id}/edit"

      expect(text(page.at_css('[data-testid="account-language"]'))).to eq('Язык: казахский')

      patch "/super_admin/accounts/#{account.id}", params: { account: { name: 'Аккаунт Алатау 3', status: 'active' } }

      expect(account.reload).to have_attributes(name: 'Аккаунт Алатау 3', locale: 'kk')
    end

    it 'does not edit the status: an account is blocked and unblocked by the button of the card (see account_blocking_spec)' do
      expect(page.css('select[name="account[status]"]')).to be_empty
    end

    it 'names every limit, explains it and offers the three choices (see account_limits_spec)' do
      rows = page.css("[data-testid='limit-rows'] [data-limit]")
      keys = %w[agents inboxes conversations non_web_inboxes storage_bytes captain_responses captain_documents captain_tokens emails]
      expect(rows.map { |row| row['data-limit'] }).to eq(keys)
      expect(rows.map { |row| text(row.at_css('.admin-limit__label')) }).to eq(
        ['Операторы', 'Каналы', 'Диалоги за 30 дней', 'Основные каналы', 'Хранилище', 'Ответы ИИ', 'Документы ИИ', 'Токены ИИ', 'Письма в день']
      )
      expect(text(rows.first.at_css('.admin-limit__hint'))).to eq('Сколько пользователей может быть в аккаунте.')
      expect(rows.first.css('label.admin-limit__option').map { |option| text(option.at_css('.admin-limit__option-title')) })
        .to eq(['Как в тарифе', 'Без ограничений', 'Своё число'])
      expect(page.css('input[name^="account[limits]"]')).to be_empty
    end

    it 'says the number of the no-limit choice in words, never as the number a plan writes' do
      account.update!(limits: { 'conversations' => ChatwootApp.max_limit })
      get "/super_admin/accounts/#{account.id}/edit"

      field = page.at_css("[data-limit='conversations']")
      expect(text(field.at_css('[data-testid="limit-now"]'))).to eq('Сейчас: без ограничений')
      expect(field.at_css('input[type=radio][checked]')['value']).to eq('plan') # the plan of this account says «без ограничений» too
      expect(field.to_html).not_to match(/100[  ]?000/)
    end

    it 'explains the excluded users in Russian' do
      expect(text(page.at_css('label[for="account_limit_counter_excluded_user_ids_raw"]'))).to eq('Не учитывать в лимите операторов')
      expect(page.at_css('textarea[name="account[limit_counter_excluded_user_ids_raw]"]')).to be_present
      expect(response.body).to include('через запятую, пробел или с новой строки')
    end

    it 'shows the spend with meters and without English' do
      expect(page.css("[data-testid='limit-rows'] [data-usage] .admin-limit__usage").size).to eq(9)
      expect(response.body).not_to match(/Unlimited|Usage is read-only|Resettable counters|Leave a field blank|Outbound|Captain responses/)
    end

    it 'replaces the raw list of flags by the grouped switches' do
      names = page.css('input[type="checkbox"][name^="enabled_features"]').map { |input| input['name'] }

      expect(names).to match_array(SuperAdmin::FineTuning.new(account).flag_names.map { |name| "enabled_features[feature_#{name}]" })
      expect(names).not_to include(
        'enabled_features[feature_custom_roles]', 'enabled_features[feature_saml]', 'enabled_features[feature_agent_management]'
      )
      expect(page.css('h3').map { |heading| text(heading) }).to include('Телефония', 'ИИ-агенты')
    end

    it 'saves what the browser sends' do
      patch "/super_admin/accounts/#{account.id}", params: {
        account: { name: 'Аккаунт Алатау 2', locale: 'kk',
                   limits: { agents: '12', storage_bytes: '1.5', emails: '' }, limit_counter_excluded_user_ids_raw: '4, 5' },
        enabled_features: { feature_sla: 'true', feature_crm: 'false' }
      }

      expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
      account.reload
      expect(account).to have_attributes(name: 'Аккаунт Алатау 2', locale: 'kk', status: 'active')
      # a blank number follows the plan, and the numbers the plan wrote stay (the older form wiped them)
      expect(account.limits).to eq(
        'agents' => 12, 'storage_bytes' => 1.5.gigabytes.to_i, 'conversations' => ChatwootApp.max_limit, 'non_web_inboxes' => ChatwootApp.max_limit
      )
      expect(account.custom_attributes['limit_counter_excluded_user_ids']).to eq([4, 5])
      expect(account.feature_enabled?('sla')).to be(true)
      expect(account.feature_enabled?('crm')).to be(false)
    end

    it 'shows the form again in Russian when a field is invalid' do
      patch "/super_admin/accounts/#{account.id}", params: { account: { name: '' } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(page.at_css('#error_explanation')).to be_present
      expect(page.css('fieldset.form-section > legend').size).to eq(3)
    end
  end
end
