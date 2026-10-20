# frozen_string_literal: true

require 'rails_helper'

# «Новый клиент»: the account, its organization, its plan and its first administrator on one page, created by one action.
RSpec.describe 'Super Admin new client', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:mail_works) { true }

  # Not memoized: some examples open several pages in a row.
  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  def error_for(field) = page.at_css("[data-error-for='#{field}']")&.text&.squish

  def params_for(overrides = {})
    {
      account: { name: 'Клиника «Алатау»', timezone: 'Asia/Almaty' },
      organization: { mode: 'none' },
      modules: %w[ai_agents],
      admin: { name: 'Айгерим Нурлан', email: 'aigerim@alatau.example', access: 'invitation' }
    }.deep_merge(overrides)
  end

  def create_client(overrides = {}) = post('/super_admin/clients', params: params_for(overrides))

  def created_account = Account.find_by(name: 'Клиника «Алатау»')

  def audits_of(record, action) = Audited::Audit.where(auditable_type: record.class.name, auditable_id: record.id, action: action)

  before do
    allow(SuperAdmin::MailState).to receive(:configured?).and_return(mail_works)
    sign_in(super_admin, scope: :super_admin)
  end

  describe 'the way in' do
    it 'sends the old address of the new account to the new page' do
      get '/super_admin/accounts/new'

      expect(response).to redirect_to('/super_admin/clients/new')
    end

    it 'is offered by the list of accounts as «Новый клиент»' do
      get '/super_admin/accounts'

      link = page.at_css('a[href="/super_admin/clients/new"]')
      expect(text(link)).to eq('Новый клиент')
      expect(page.at_css('a[href="/super_admin/accounts/new"]')).to be_nil
    end

    it 'needs a super admin' do
      sign_out(:super_admin)

      get '/super_admin/clients/new'

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include('/super_admin/sign_in')
    end

    it 'keeps «Аккаунты» marked in the menu' do
      get '/super_admin/clients/new'

      expect(page.css('nav a[aria-current="page"]').map { |anchor| text(anchor) }).to eq(['Аккаунты'])
    end
  end

  describe 'the form' do
    before { get '/super_admin/clients/new' }

    it 'is titled «Новый клиент» and has the four sections in order' do
      expect(response).to have_http_status(:ok)
      expect(text(page.at_css('h1'))).to eq('Новый клиент')
      titles = page.css('main form h2.admin-block__title').map { |title| text(title) }
      expect(titles).to eq(['Аккаунт', 'Организация', 'Тариф', 'Первый администратор'])
      expect(response.body).not_to include('translation missing')
    end

    it 'asks for the name, says the language is Russian as text and offers the time zone with Astana chosen' do
      expect(text(page.at_css('label[for="account_name"]'))).to eq('Название аккаунта')
      expect(text(page.at_css('[data-testid="account-language"]'))).to eq('Язык: русский')
      expect(page.css('[name="account[locale]"]')).to be_empty
      expect(response.body).not_to include('Қазақша', 'English')
      expect(response.body).to include('Платформа пока работает только на русском, поэтому язык аккаунта не выбирается.')

      select = page.at_css('select[name="account[timezone]"]')
      expect(select.at_css('option[selected]')['value']).to eq('Asia/Almaty')
      expect(text(select.at_css('option[selected]'))).to eq('Астана, Алматы (UTC+5)')
      expect(select.css('option').size).to be > 5
    end

    it 'chooses «Без организации» and says no organization can be picked while there is none' do
      choices = page.css('[data-testid="client-organization-block"] input[name="organization[mode]"]')

      expect(choices.map { |choice| choice['value'] }).to eq(%w[none existing new])
      expect(choices.find { |choice| choice['checked'] }['value']).to eq('none')
      expect(choices.find { |choice| choice['value'] == 'existing' }['disabled']).to be_present
      expect(page.at_css('[data-testid="client-organization-block"]').text).to include('Организаций пока нет')
    end

    it 'shows the base as always included, the modules unchecked and an optional trial' do
      plan = page.at_css('[data-testid="new-plan-block"]')

      expect(text(plan.at_css('[data-plan-card="base"]'))).to include('База', 'Всегда включена')
      boxes = plan.css('input[type="checkbox"][name="modules[]"]')
      expect(boxes.map { |box| box['value'] }).to eq(%w[ai_agents broadcasts quality extensions])
      expect(boxes.map { |box| box['checked'] }).to all(be_nil)
      trial = page.at_css('[data-testid="new-trial-block"] input[name="start_trial"]')
      expect(trial['checked']).to be_nil
    end

    it 'does not ask for limits, the status or single functions: the limits come from the plan' do
      expect(page.css('input[name^="account[limits]"], select[name="account[status]"], input[name^="enabled_features"]')).to be_empty
      expect(text(page.at_css('[data-testid="limits-note"]'))).to include('Лимиты операторов и хранилища берутся из тарифа')
    end

    it 'asks for the name and the e-mail of the administrator and offers an invitation or a password' do
      expect(page.at_css('input[name="admin[name]"]')).to be_present
      expect(page.at_css('input[name="admin[email]"]')).to be_present
      choices = page.css('input[name="admin[access]"]')
      expect(choices.map { |choice| choice['value'] }).to eq(%w[invitation password])
      expect(page.at_css('input[name="admin[password]"]')).to be_present
      expect(page.at_css('[data-testid="adopt-existing"]')).to be_nil
    end

    context 'when the mail of the platform works' do
      it 'says so and chooses the invitation' do
        expect(text(page.at_css('[data-testid="mail-state"]'))).to eq('Почта платформы работает')
        choices = page.css('input[name="admin[access]"]')
        expect(choices.find { |choice| choice['checked'] }['value']).to eq('invitation')
        expect(choices.find { |choice| choice['value'] == 'invitation' }['disabled']).to be_nil
      end
    end

    context 'when the mail of the platform is not set up' do
      let(:mail_works) { false }

      it 'says so, disables the invitation and chooses the password' do
        expect(text(page.at_css('[data-testid="mail-state"]'))).to eq('Почта не настроена — письмо не уйдёт, задайте пароль')
        choices = page.css('input[name="admin[access]"]')
        expect(choices.find { |choice| choice['value'] == 'invitation' }['disabled']).to be_present
        expect(choices.find { |choice| choice['checked'] }['value']).to eq('password')
      end
    end

    it 'lists the rules of the password, none of them followed by an empty field' do
      rules = page.css('[data-password-rules] li')

      expect(rules.map { |rule| rule['data-rule'] }).to eq(%w[length uppercase lowercase number special])
      expect(rules.map { |rule| rule['data-state'] }).to all(eq('todo'))
      expect(text(rules.first)).to eq('не меньше 6 знаков')
    end

    it 'offers the organizations there are, by name' do
      create(:organization, name: 'Алатау Групп')

      get '/super_admin/clients/new'

      select = page.at_css('select[name="organization[id]"]')
      expect(select.css('option').map { |option| text(option) }).to include('Выберите организацию', a_string_starting_with('Алатау Групп'))
      expect(page.at_css('input[name="organization[mode]"][value="existing"]')['disabled']).to be_nil
    end
  end

  describe 'creating a client with an invitation' do
    it 'creates the account, the plan and the administrator, sends one letter and says «Готово»' do
      expect do
        perform_enqueued_jobs { create_client }
      end.to change(Account, :count).by(1).and change(User, :count).by(1).and change(AccountUser, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(text(page.at_css('h1'))).to eq('Готово: клиент подключён')

      account = created_account
      expect(account).to have_attributes(locale: 'ru', reporting_timezone: 'Asia/Almaty', workspace_timezone: 'Asia/Almaty', status: 'active')
      expect(account.custom_attributes).to include('plan' => 'base', 'plan_modules' => %w[ai_agents])
      expect(account.feature_enabled?('captain_integration')).to be(true)
      expect(account.organization).to be_nil
      expect(account).not_to be_trial

      user = User.find_by!(email: 'aigerim@alatau.example')
      expect(user).to have_attributes(name: 'Айгерим Нурлан')
      expect(user).not_to be_confirmed
      membership = AccountUser.find_by!(account: account, user: user)
      expect(membership).to have_attributes(role: 'administrator', inviter_id: super_admin.id, availability: 'offline')
    end

    it 'sends exactly one letter, with the link where the person sets a password' do
      perform_enqueued_jobs { create_client }

      letters = ActionMailer::Base.deliveries.select { |mail| mail.to == ['aigerim@alatau.example'] }
      expect(letters.size).to eq(1)
      expect(letters.first.body.encoded).to include('auth/password/edit?reset_password_token=')
    end

    it 'says the letter was sent, how long the link lives, and offers the card but not the entry yet' do
      create_client

      lines = page.css('[data-testid="created-line"]').map { |line| text(line) }
      expect(lines).to include(
        "Аккаунт создан: Клиника «Алатау» (##{created_account.id}). Язык: русский, часовой пояс: Астана, Алматы (UTC+5).",
        'Организация: без организации.',
        'Тариф: База + ИИ-агенты.',
        'Приглашение отправлено на aigerim@alatau.example. Ссылка в письме действует 6 ч.; если человек не успеет, на странице входа есть «Забыли пароль?».'
      )
      expect(page.at_css('[data-testid="one-time-password"]')).to be_nil
      expect(page.at_css('[data-testid="created-card-link"]')['href']).to eq("/super_admin/accounts/#{created_account.id}")
      expect(page.at_css('[data-testid="created-enter"]')).to be_nil
      expect(text(page.at_css('[data-testid="created-enter-waits"]'))).to include('когда он примет приглашение')
    end

    it 'tells the browser not to keep the page' do
      create_client

      expect(response.headers['Cache-Control']).to include('no-store')
    end

    it 'leaves entries in the audit log: the client, the plan, the new user and the membership, signed by the super admin' do
      create_client

      account = created_account
      expect(audits_of(account, 'create_client').first.audited_changes).to include(
        'name' => 'Клиника «Алатау»', 'timezone' => 'Asia/Almaty', 'modules' => %w[ai_agents], 'trial' => false,
        'organization_id' => nil, 'administrator' => { 'email' => 'aigerim@alatau.example', 'access' => 'invitation' }
      )
      expect(audits_of(account, 'create_client').first.user).to eq(super_admin)
      expect(audits_of(account, 'apply_plan')).to exist
      user = User.find_by!(email: 'aigerim@alatau.example')
      user_audit = audits_of(user, 'create').first
      expect(user_audit.audited_changes).to include('email' => 'aigerim@alatau.example', 'access' => 'invitation')
      expect(user_audit.user).to eq(super_admin)
      expect(Audited::Audit.where(auditable_type: 'AccountUser', associated_id: account.id, action: 'create')).to exist
    end
  end

  describe 'creating a client with a password' do
    let(:password) { 'Sezim-2026x' }

    def create_with_password = create_client(admin: { access: 'password', password: password })

    it 'confirms the person, lets them sign in with it and sends no letter' do
      perform_enqueued_jobs { create_with_password }

      expect(response).to have_http_status(:ok)
      user = User.find_by!(email: 'aigerim@alatau.example')
      expect(user).to be_confirmed
      expect(user.valid_password?(password)).to be(true)
      expect(ActionMailer::Base.deliveries.select { |mail| mail.to == ['aigerim@alatau.example'] }).to be_empty
      expect(AccountUser.find_by!(account: created_account, user: user).role).to eq('administrator')
    end

    it 'shows the password once, with a copy button, and offers the entry into the account' do
      create_with_password

      block = page.at_css('[data-testid="one-time-password"]')
      expect(block.at_css('input[readonly]')['value']).to eq(password)
      expect(block.at_css('button[data-password-copy]')).to be_present
      expect(text(block)).to include('Пароль показан один раз')
      expect(page.css('[data-testid="created-line"]').map { |line| text(line) }).to include('Пароль для aigerim@alatau.example задан.')
      expect(page.at_css('[data-testid="created-enter"]')).to be_present
      expect(response.headers['Cache-Control']).to include('no-store')
    end

    it 'shows the password on no other page and writes it nowhere' do
      create_with_password

      get "/super_admin/accounts/#{created_account.id}"
      expect(response.body).not_to include(password)
      get '/super_admin/audits'
      expect(response.body).not_to include(password)
      expect(Audited::Audit.all.map { |audit| audit.audited_changes.to_json }.join).not_to include(password)
      expect(flash.to_h.values.join).not_to include(password)
    end

    it 'works when the mail is not set up' do
      allow(SuperAdmin::MailState).to receive(:configured?).and_return(false)

      expect { create_with_password }.to change(Account, :count).by(1)
      expect(response).to have_http_status(:ok)
    end

    it 'records that the person got a password, not the password' do
      create_with_password

      expect(audits_of(created_account, 'create_client').first.audited_changes['administrator']).to eq(
        'email' => 'aigerim@alatau.example', 'access' => 'password'
      )
    end
  end

  describe 'the organization' do
    it 'links the account to the organization that was chosen' do
      organization = create(:organization, name: 'Алатау Групп')

      create_client(organization: { mode: 'existing', id: organization.id.to_s })

      expect(created_account.organization).to eq(organization)
      expect(page.css('[data-testid="created-line"]').map { |line| text(line) }).to include('Организация: аккаунт привязан к «Алатау Групп».')
      expect(audits_of(created_account, 'link_organization')).to exist
      expect(audits_of(organization, 'link_account')).to exist
      expect(audits_of(created_account, 'create_client').first.audited_changes).to include('organization_id' => organization.id, 'organization_created' => false)
    end

    it 'creates a new organization with its БИН and links the account to it' do
      bin = build(:organization, :with_requisites).bin

      expect do
        create_client(organization: { mode: 'new', name: 'ТОО Алатау', bin: bin })
      end.to change(Organization, :count).by(1)

      organization = Organization.find_by!(name: 'ТОО Алатау')
      expect(organization.bin).to eq(bin)
      expect(created_account.organization).to eq(organization)
      expect(page.css('[data-testid="created-line"]').map { |line| text(line) }).to include('Организация: создана «ТОО Алатау», аккаунт привязан к ней.')
      expect(audits_of(organization, 'create')).to exist
      expect(audits_of(created_account, 'create_client').first.audited_changes).to include('organization_created' => true)
    end

    it 'creates a new organization without a БИН' do
      expect { create_client(organization: { mode: 'new', name: 'ТОО Без БИН', bin: '' }) }.to change(Organization, :count).by(1)

      expect(Organization.find_by!(name: 'ТОО Без БИН').bin).to be_nil
    end
  end

  describe 'the trial and the plan' do
    it 'starts a trial on top of the plan when asked and says until when' do
      create_client(start_trial: '1')

      account = created_account
      expect(account).to be_trial_active
      expect(account.custom_attributes).to include('plan' => 'base', 'plan_modules' => %w[ai_agents])
      expect(audits_of(account, 'start_trial')).to exist
      expect(page.css('[data-testid="created-line"]').map { |line| text(line) }).to include(a_string_matching(/\AПробный период до \d{2}\.\d{2}\.\d{4} \d{2}:\d{2} \(Астана\)\.\z/))
    end

    it 'applies the base alone when no module is chosen, and leaves the limits to the plan' do
      create_client(modules: [])

      account = created_account
      expect(account.custom_attributes).to include('plan' => 'base', 'plan_modules' => [])
      expect(account.limits).not_to include('agents' => 0)
      expect(account).not_to be_trial
    end
  end

  describe 'a form with a problem' do
    it 'is drawn again with everything typed and the problems under their fields, and creates nothing' do
      organization_params = { mode: 'new', name: '', bin: '123' }
      expect do
        create_client(account: { name: '', timezone: 'Europe/Moscow' }, organization: organization_params, modules: %w[quality broadcasts], start_trial: '1',
                      admin: { name: '', email: 'not-an-email', access: 'password', password: 'abc' })
      end.not_to change { [Account.count, Organization.count, User.count, AccountUser.count] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(text(page.at_css('[data-testid="client-errors"]'))).to include('Клиент не создан, ничего не сохранено')
      expect(error_for('account_name')).to eq('Введите название аккаунта.')
      expect(error_for('organization_name')).to eq('Введите название организации.')
      expect(error_for('organization_bin')).to be_present
      expect(error_for('admin_name')).to eq('Введите имя и фамилию.')
      expect(error_for('admin_email')).to eq('Проверьте e-mail: в нём ошибка.')

      expect(page.at_css('select[name="account[timezone]"] option[selected]')['value']).to eq('Europe/Moscow')
      expect(page.at_css('input[name="organization[mode]"][value="new"]')['checked']).to be_present
      expect(page.at_css('input[name="organization[bin]"]')['value']).to eq('123')
      expect(page.css('input[name="modules[]"][checked]').map { |box| box['value'] }).to eq(%w[broadcasts quality])
      expect(page.at_css('input[name="start_trial"]')['checked']).to be_present
      expect(page.at_css('input[name="admin[email]"]')['value']).to eq('not-an-email')
      expect(page.at_css('input[name="admin[access]"][value="password"]')['checked']).to be_present
      expect(page.at_css('input[name="admin[password]"]')['value']).to eq('abc')
    end

    it 'does not show the problems of a form that was just opened' do
      get '/super_admin/clients/new'

      expect(page.css('[data-error-for]')).to be_empty
      expect(page.at_css('[data-testid="client-errors"]')).to be_nil
    end

    it 'names every rule a weak password breaks, in Russian' do
      create_client(admin: { access: 'password', password: 'abc' })

      expect(error_for('admin_password')).to eq(
        'Пароль не подходит. Нужно: не меньше 6 знаков; заглавную латинскую букву; цифру; спецсимвол (например ! @ # $ %).'
      )
      expect(page.css('[data-password-rules] li').to_h { |rule| [rule['data-rule'], rule['data-state']] }).to eq(
        'length' => 'todo', 'uppercase' => 'todo', 'lowercase' => 'ok', 'number' => 'todo', 'special' => 'todo'
      )
    end

    it 'refuses a password with Russian letters' do
      create_client(admin: { access: 'password', password: 'Пароль-2026' })

      expect(error_for('admin_password')).to include('русские буквы не подходят')
    end

    it 'asks for a password when the password is chosen and the field is empty' do
      create_client(admin: { access: 'password', password: '' })

      expect(error_for('admin_password')).to eq('Введите пароль или нажмите «Сгенерировать».')
    end

    it 'does not take a long name' do
      create_client(account: { name: 'А' * 256 })

      expect(error_for('account_name')).to include('длиннее 255')
    end

    it 'refuses a БИН with a wrong control digit' do
      create_client(organization: { mode: 'new', name: 'ТОО Ошибка', bin: '980140000123' })

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_for('organization_bin')).to be_present
      expect(Organization.where(name: 'ТОО Ошибка')).to be_empty
    end

    it 'points to the list when the БИН belongs to an organization that exists' do
      existing = create(:organization, :with_requisites)

      create_client(organization: { mode: 'new', name: 'Двойник', bin: existing.bin })

      expect(error_for('organization_bin')).to eq('Организация с таким БИН уже есть: выберите её из списка.')
    end

    it 'asks to choose an organization when «Выбрать из списка» is chosen and none is' do
      create(:organization)

      create_client(organization: { mode: 'existing', id: '' })

      expect(error_for('organization_id')).to eq('Выберите организацию из списка.')
    end

    it 'does not take a time zone outside the list, an unknown module or an unknown way to name the organization' do
      create_client(account: { timezone: 'Mars/Olympus' }, modules: %w[ghost], organization: { mode: 'bogus' })

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_for('timezone')).to eq('Выберите часовой пояс из списка.')
      expect(error_for('modules')).to be_present
      expect(error_for('organization_mode')).to eq('Выберите, как указать организацию.')
      expect(Account.where(name: 'Клиника «Алатау»')).to be_empty
    end

    it 'takes only text: a list or a map where a field is expected is an empty value' do
      post '/super_admin/clients', params: { account: { name: %w[a b] }, admin: { email: { x: 1 } } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_for('account_name')).to eq('Введите название аккаунта.')
      expect(error_for('admin_email')).to eq('Введите e-mail.')
    end

    context 'when the mail of the platform is not set up' do
      let(:mail_works) { false }

      it 'does not take the invitation: the letter would go nowhere' do
        expect { create_client }.not_to change(Account, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(error_for('admin_access')).to eq('Почта платформы не настроена, письмо не уйдёт. Задайте пароль.')
      end
    end
  end

  describe 'a person who is on the platform already' do
    let!(:existing) { create(:user, name: 'Бауыржан Сейт', email: 'bauyrzhan@alatau.example', password: 'Secret-2026y') }

    it 'is not created again: the form says who has the e-mail and offers to add them, creating nothing' do
      expect do
        create_client(admin: { email: 'bauyrzhan@alatau.example' })
      end.not_to change { [Account.count, User.count] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_for('admin_email')).to eq('Пользователь с таким e-mail уже есть: Бауыржан Сейт.')
      expect(page.at_css('[data-testid="adopt-existing"]')).to be_present
      expect(page.at_css('input[name="admin[adopt]"]')['checked']).to be_nil
    end

    it 'joins the new account as its administrator when the super admin says so, and nothing about the person changes' do
      before = existing.reload.attributes.slice('encrypted_password', 'name', 'confirmed_at', 'email')

      expect do
        perform_enqueued_jobs { create_client(admin: { email: 'bauyrzhan@alatau.example', adopt: '1', access: 'invitation' }) }
      end.to change(Account, :count).by(1).and change(User, :count).by(0)

      expect(response).to have_http_status(:ok)
      expect(existing.reload.attributes.slice('encrypted_password', 'name', 'confirmed_at', 'email')).to eq(before)
      expect(AccountUser.find_by!(account: created_account, user: existing).role).to eq('administrator')
      expect(ActionMailer::Base.deliveries.select { |mail| mail.to == ['bauyrzhan@alatau.example'] }).to be_empty
      expect(page.css('[data-testid="created-line"]').map { |line| text(line) }).to include(
        'Бауыржан Сейт (bauyrzhan@alatau.example) стал администратором аккаунта. Его пароль не менялся.'
      )
      expect(audits_of(created_account, 'create_client').first.audited_changes['administrator']).to eq(
        'email' => 'bauyrzhan@alatau.example', 'access' => 'existing'
      )
    end

    it 'matches the e-mail whatever its case' do
      create_client(admin: { email: 'Bauyrzhan@Alatau.Example' })

      expect(error_for('admin_email')).to include('Бауыржан Сейт')
    end
  end

  describe 'one action' do
    it 'saves nothing when the last step fails: no account, no organization, no user' do
      allow(AccountUser).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect do
        create_client(organization: { mode: 'new', name: 'ТОО Откат', bin: '' }, start_trial: '1')
      end.not_to change { [Account.count, Organization.count, User.count, AccountUser.count] }

      expect(response).to have_http_status(:unprocessable_content)
      expect(text(page.at_css('[data-testid="client-errors"]'))).to include('ничего не сохранено')
      expect(page.at_css('input[name="account[name]"]')['value']).to eq('Клиника «Алатау»')
      expect(page.at_css('input[name="organization[name]"]')['value']).to eq('ТОО Откат')
      expect(Audited::Audit.where(action: %w[create_client apply_plan start_trial link_organization])).to be_empty
    end

    it 'shows an e-mail taken a moment ago on its field' do
      allow(User).to receive(:from_email).and_return(nil)
      create(:user, email: 'aigerim@alatau.example')

      expect { create_client }.not_to change(Account, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_for('admin_email')).to include('уже есть')
    end

    it 'keeps the client when the letter cannot be handed over, and says so' do
      allow_any_instance_of(User).to receive(:send_confirmation_instructions).and_raise(StandardError, 'no queue') # rubocop:disable RSpec/AnyInstance

      expect { create_client }.to change(Account, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(page.css('[data-testid="created-line"]').map { |line| text(line) }).to include(
        'Приглашение на aigerim@alatau.example отправить не удалось. Откройте карточку пользователя и задайте ему пароль.'
      )
    end

    it 'makes the first person an administrator whatever the request says' do
      create_client(admin: { role: 'agent', mode: 'pick', user_id: '1' })

      expect(AccountUser.find_by!(account: created_account, user: User.find_by!(email: 'aigerim@alatau.example')).role).to eq('administrator')
    end

    it 'does not leave the account of the super admin in the thread of the request' do
      Current.account = nil

      create_client

      expect(Current.account).to be_nil
    end
  end

  describe 'the card of the account made here' do
    it 'shows the time zone by its name' do
      create_client

      get "/super_admin/accounts/#{created_account.id}"

      expect(text(page.at_css('[data-testid="info-block"]'))).to include('Астана, Алматы (UTC+5)')
    end
  end
end
