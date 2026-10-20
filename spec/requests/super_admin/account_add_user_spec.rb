# frozen_string_literal: true

require 'rails_helper'

# «Добавить пользователя» in the «Пользователи» block of the account card: somebody who is on the platform already (picked from the
# list) or a new person with an invitation by e-mail or a password the super admin sets.
RSpec.describe 'Super Admin adding a user to an account', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account, name: 'Клиника «Сезим»') }
  let(:mail_works) { true }

  # Not memoized: some examples open several pages in a row.
  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  def error_for(field) = page.at_css("[data-testid='add-user'] [data-error-for='#{field}']")&.text&.squish

  def add_user(member) = post("/super_admin/accounts/#{account.id}/add_user", params: { member: member })

  def new_person(overrides = {})
    { mode: 'create', name: 'Динара Касым', email: 'dinara@sezim.example', role: 'agent', access: 'invitation' }.merge(overrides)
  end

  def membership_of(user) = AccountUser.find_by(account: account, user: user)

  before do
    allow(SuperAdmin::MailState).to receive(:configured?).and_return(mail_works)
    create(:user, account: account, role: :administrator, name: 'Первый Админ')
    sign_in(super_admin, scope: :super_admin)
  end

  describe 'the block' do
    before { get "/super_admin/accounts/#{account.id}" }

    it 'has a collapsed «Добавить пользователя» form with two ways: a user from the list and a new one' do
      block = page.at_css('[data-testid="add-user"]')

      expect(block.has_attribute?('open')).to be(false)
      expect(text(block.at_css('summary'))).to eq('Добавить пользователя')
      expect(block.at_css('form')['action']).to eq("/super_admin/accounts/#{account.id}/add_user")
      expect(block.css('input[name="member[mode]"]').map { |choice| choice['value'] }).to eq(%w[pick create])
      expect(block.at_css('input[name="member[mode]"][checked]')['value']).to eq('pick')
    end

    it 'says its problems itself, in Russian under the fields, and is sent once' do
      form = page.at_css('[data-testid="add-user"] form')

      expect(form.has_attribute?('novalidate')).to be(true)
      expect(form['data-single-submit']).to eq('true')
    end

    it 'picks an existing user with the search of the user field' do
      select = page.at_css('[data-testid="add-user"] select[name="member[user_id]"]')

      expect(select['data-url']).to eq('/super_admin/users.json')
      expect(select.ancestors('.field-unit--belongs-to-search')).to be_present
    end

    it 'asks a new person for the name and e-mail, and for an invitation or a password' do
      block = page.at_css('[data-testid="add-user"]')

      expect(block.at_css('input[name="member[name]"]')).to be_present
      expect(block.at_css('input[name="member[email]"]')).to be_present
      expect(block.css('input[name="member[access]"]').map { |choice| choice['value'] }).to eq(%w[invitation password])
      expect(text(block.at_css('[data-testid="mail-state"]'))).to eq('Почта платформы работает')
      expect(block.at_css('input[name="member[password]"]')).to be_present
    end

    it 'offers the roles by name, an operator first' do
      options = page.css('[data-testid="add-user"] select[name="member[role]"] option')

      expect(options.map { |option| [text(option), option['value']] }).to eq([%w[Оператор agent], %w[Администратор administrator]])
      expect(options.find { |option| option['selected'] }['value']).to eq('agent')
    end

    context 'when the mail of the platform is not set up' do
      let(:mail_works) { false }

      it 'says so, disables the invitation and chooses the password' do
        block = page.at_css('[data-testid="add-user"]')

        expect(text(block.at_css('[data-testid="mail-state"]'))).to eq('Почта не настроена — письмо не уйдёт, задайте пароль')
        expect(block.at_css('input[name="member[access]"][value="invitation"]')['disabled']).to be_present
        expect(block.at_css('input[name="member[access]"][checked]')['value']).to eq('password')
      end
    end
  end

  describe 'adding somebody who is on the platform already' do
    let!(:person) { create(:user, name: 'Ербол Туран', email: 'erbol@example.test', password: 'Secret-2026y') }

    it 'adds them with the chosen role, changes nothing about them and goes back to the card' do
      before = person.reload.attributes.slice('encrypted_password', 'name', 'confirmed_at', 'email')

      expect { add_user(mode: 'pick', user_id: person.id.to_s, role: 'administrator') }.to change { account.account_users.count }.by(1)

      expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
      expect(membership_of(person)).to have_attributes(role: 'administrator', inviter_id: super_admin.id)
      expect(person.reload.attributes.slice('encrypted_password', 'name', 'confirmed_at', 'email')).to eq(before)
      follow_redirect!
      expect(page.at_css('.flashes').text).to include('Ербол Туран добавлен(а) в аккаунт: администратор.')
      expect(page.at_css('[data-testid="users-block"]').text).to include('erbol@example.test')
    end

    it 'leaves an entry in the audit log of the account' do
      add_user(mode: 'pick', user_id: person.id.to_s, role: 'agent')

      audit = Audited::Audit.find_by!(auditable_type: 'Account', auditable_id: account.id, action: 'add_user')
      expect(audit.audited_changes).to include(
        'user_id' => person.id, 'email' => 'erbol@example.test', 'role' => 'agent', 'new_user' => false, 'access' => 'existing'
      )
      expect(audit.user).to eq(super_admin)
    end

    it 'sends no letter' do
      perform_enqueued_jobs(only: ApplicationMailDeliveryJob) { add_user(mode: 'pick', user_id: person.id.to_s, role: 'agent') }

      expect(ActionMailer::Base.deliveries.select { |mail| mail.to == ['erbol@example.test'] }).to be_empty
    end

    it 'asks to choose somebody when nobody is chosen, and keeps the role' do
      expect { add_user(mode: 'pick', user_id: '', role: 'administrator') }.not_to(change { account.account_users.count })

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_for('user')).to eq('Выберите пользователя из списка.')
      expect(page.at_css('[data-testid="add-user"]').has_attribute?('open')).to be(true)
      expect(page.at_css('select[name="member[role]"] option[selected]')['value']).to eq('administrator')
      expect(text(page.at_css('[data-testid="add-user-errors"]'))).to include('Пользователь не добавлен')
    end

    it 'says so, in red, when the person is in the account already, and keeps who was chosen' do
      create(:account_user, account: account, user: person, role: :agent)

      add_user(mode: 'pick', user_id: person.id.to_s, role: 'administrator')

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_for('user')).to eq('Ербол Туран уже состоит в этом аккаунте: оператор.')
      expect(page.at_css('select[name="member[user_id]"] option[selected]')['value']).to eq(person.id.to_s)
      expect(membership_of(person).role).to eq('agent')
    end

    it 'does not take a user that does not exist' do
      add_user(mode: 'pick', user_id: '999999999', role: 'agent')

      expect(error_for('user')).to eq('Выберите пользователя из списка.')
    end

    it 'does not take a role outside the list' do
      expect { add_user(mode: 'pick', user_id: person.id.to_s, role: 'owner') }.not_to(change { account.account_users.count })

      expect(error_for('role')).to eq('Выберите роль из списка.')
    end
  end

  describe 'adding a new person with an invitation' do
    it 'creates the user, adds them with the role, sends one letter and goes back to the card' do
      expect do
        perform_enqueued_jobs(only: ApplicationMailDeliveryJob) { add_user(new_person(role: 'administrator')) }
      end.to change(User, :count).by(1).and change { account.account_users.count }.by(1)

      expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
      user = User.find_by!(email: 'dinara@sezim.example')
      expect(user).not_to be_confirmed
      expect(membership_of(user)).to have_attributes(role: 'administrator', inviter_id: super_admin.id, availability: 'offline')
      letters = ActionMailer::Base.deliveries.select { |mail| mail.to == ['dinara@sezim.example'] }
      expect(letters.size).to eq(1)
      expect(letters.first.body.encoded).to include('auth/password/edit?reset_password_token=')
      follow_redirect!
      expect(page.at_css('.flashes').text).to include(
        'Динара Касым добавлен(а) в аккаунт: администратор. Приглашение отправлено на dinara@sezim.example.'
      )
    end

    it 'leaves entries: the new user (with the way, not a password) and the user added to the account' do
      add_user(new_person)

      audit = Audited::Audit.find_by!(auditable_type: 'Account', auditable_id: account.id, action: 'add_user')
      expect(audit.audited_changes).to include('email' => 'dinara@sezim.example', 'new_user' => true, 'access' => 'invitation')
      user = User.find_by!(email: 'dinara@sezim.example')
      user_audit = Audited::Audit.find_by!(auditable_type: 'User', auditable_id: user.id, action: 'create')
      expect(user_audit.audited_changes).to include('access' => 'invitation')
    end

    it 'goes back to the card even when the form was sent again from the page of an earlier mistake' do
      referer = "http://www.example.com/super_admin/accounts/#{account.id}/add_user"

      post "/super_admin/accounts/#{account.id}/add_user", params: { member: new_person }, headers: { 'HTTP_REFERER' => referer }

      expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
    end

    it 'does not take the invitation while the mail of the platform is not set up' do
      allow(SuperAdmin::MailState).to receive(:configured?).and_return(false)

      expect { add_user(new_person) }.not_to change(User, :count)

      expect(error_for('access')).to eq('Почта платформы не настроена, письмо не уйдёт. Задайте пароль.')
    end

    it 'says the invitation could not be sent, and still adds the person' do
      allow_any_instance_of(User).to receive(:send_confirmation_instructions).and_raise(StandardError, 'no queue') # rubocop:disable RSpec/AnyInstance

      expect { add_user(new_person) }.to change { account.account_users.count }.by(1)

      follow_redirect!
      expect(page.at_css('.flashes').text).to include('Приглашение отправить не удалось')
    end
  end

  describe 'adding a new person with a password' do
    let(:password) { 'Sezim-2026x' }

    def add_with_password(overrides = {}) = add_user(new_person(access: 'password', password: password).merge(overrides))

    it 'confirms the person, adds them, and shows the password once on the card itself', :aggregate_failures do
      perform_enqueued_jobs(only: ApplicationMailDeliveryJob) { add_with_password }

      expect(response).to have_http_status(:ok)
      user = User.find_by!(email: 'dinara@sezim.example')
      expect(user).to be_confirmed
      expect(user.valid_password?(password)).to be(true)
      expect(membership_of(user).role).to eq('agent')
      expect(ActionMailer::Base.deliveries.select { |mail| mail.to == ['dinara@sezim.example'] }).to be_empty

      block = page.at_css('[data-testid="added-member-password"]')
      expect(block.at_css('input[readonly]')['value']).to eq(password)
      expect(block.at_css('button[data-password-copy]')).to be_present
      expect(text(block)).to include('Пароль для dinara@sezim.example', 'Пароль показан один раз')
      expect(page.at_css('.flash-notice').text).to include('Пароль задан')
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(page.at_css('[data-testid="users-block"]').text).to include('dinara@sezim.example')
    end

    it 'hands over the e-mail and the address of sign-in with the password, each with a copy button', :aggregate_failures do
      with_modified_env(FRONTEND_URL: 'https://app.example.test') { add_with_password }

      rows = page.css('[data-testid="added-member-password"] [data-sign-in]')
      expect(rows.to_h { |row| [row['data-sign-in'], row.at_css('input[readonly]')['value']] }).to eq(
        'password' => password, 'email' => 'dinara@sezim.example', 'address' => 'https://app.example.test/app/login'
      )
      expect(rows.map { |row| row.at_css('button[data-password-copy]')['data-copy-from'] }).to eq(rows.map { |row| row.at_css('input')['id'] })
    end

    it 'shows the password on no other page and writes it nowhere' do
      add_with_password

      get "/super_admin/accounts/#{account.id}"
      expect(response.body).not_to include(password)
      expect(Audited::Audit.all.map { |audit| audit.audited_changes.to_json }.join).not_to include(password)
    end

    it 'works while the mail of the platform is not set up' do
      allow(SuperAdmin::MailState).to receive(:configured?).and_return(false)

      expect { add_with_password }.to change(User, :count).by(1)
    end

    it 'names what a weak password lacks, keeps everything typed and adds nobody', :aggregate_failures do
      expect { add_with_password(password: 'abcdef') }.not_to change(User, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_for('password')).to eq(
        'Пароль не подходит: он должен содержать заглавную латинскую букву; цифру; спецсимвол (например ! @ # $ %).'
      )
      expect(page.at_css('input[name="member[name]"]')['value']).to eq('Динара Касым')
      expect(page.at_css('input[name="member[email]"]')['value']).to eq('dinara@sezim.example')
      expect(page.at_css('input[name="member[password]"]')['value']).to eq('abcdef')
      expect(page.at_css('input[name="member[mode]"][value="create"]')['checked']).to be_present
      expect(page.at_css('input[name="member[access]"][value="password"]')['checked']).to be_present
      expect(page.at_css('[data-testid="add-user"]').has_attribute?('open')).to be(true)
    end
  end

  describe 'a problem with the new person' do
    it 'shows every problem at once under the fields' do
      add_user(mode: 'create', name: '', email: 'broken', role: 'agent', access: 'password', password: '')

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_for('email')).to eq('Проверьте e-mail: в нём ошибка.')
      expect(page.at_css('[data-testid="add-user-errors"]').text).to include('Пользователь не добавлен')
    end

    it 'says a mistyped e-mail is a mistake, in Russian and on the field, not that a developer is needed', :aggregate_failures do
      ['ivan@clinic', 'ivan@клиника.kz'].each do |typo|
        expect { add_user(new_person(email: typo)) }.not_to(change { [User.count, AccountUser.count] })

        expect(response).to have_http_status(:unprocessable_content)
        expect(error_for('email')).to eq('Проверьте e-mail: в нём ошибка.')
        expect(page.at_css('[data-testid="add-user-errors"]').text).not_to include('разработчику')
        expect(page.at_css('[data-testid="add-user"] [data-testid="adopt-existing"]')).to be_nil
      end
    end

    it 'says the same when the e-mail gets past the check and the save of the user refuses it' do
      allow_any_instance_of(SuperAdmin::AccountMember).to receive(:email_accepted?).and_return(true) # rubocop:disable RSpec/AnyInstance

      expect { add_user(new_person(email: 'ivan@clinic')) }.not_to(change { [User.count, AccountUser.count] })

      expect(response).to have_http_status(:unprocessable_content)
      expect(error_for('email')).to eq('Проверьте e-mail: в нём ошибка.')
      expect(page.at_css('[data-testid="add-user-errors"]').text).not_to include('разработчику')
    end

    it 'names the owner of an e-mail taken a moment ago and offers to add them' do
      taken = create(:user, name: 'Нурлан Аман', email: 'dinara@sezim.example')
      calls = 0
      allow(User).to receive(:from_email) { (calls += 1) == 1 ? nil : taken }

      expect { add_user(new_person) }.not_to(change { [User.count, AccountUser.count] })

      expect(error_for('email')).to eq('Пользователь с таким e-mail уже есть: Нурлан Аман.')
      expect(page.at_css('[data-testid="add-user"] [data-testid="adopt-existing"]')).to be_present
    end

    it 'asks for the name and the way' do
      add_user(mode: 'create', name: '', email: 'ok@example.test', role: 'agent', access: '')

      expect(error_for('name')).to eq('Введите имя и фамилию.')
      expect(error_for('access')).to eq('Выберите, как человек получит доступ.')
    end

    context 'when somebody has the e-mail already' do
      let!(:person) { create(:user, name: 'Ербол Туран', email: 'erbol@example.test', password: 'Secret-2026y') }

      it 'does not create them again and offers to add them' do
        expect { add_user(new_person(email: 'erbol@example.test')) }.not_to change(User, :count)

        expect(error_for('email')).to eq('Пользователь с таким e-mail уже есть: Ербол Туран.')
        expect(page.at_css('[data-testid="add-user"] [data-testid="adopt-existing"]')).to be_present
      end

      it 'adds them when the super admin says so, and nothing about them changes' do
        before = person.reload.attributes.slice('encrypted_password', 'name', 'confirmed_at')

        expect do
          add_user(new_person(email: 'erbol@example.test', adopt: '1', role: 'administrator'))
        end.not_to change(User, :count)

        expect(response).to redirect_to("/super_admin/accounts/#{account.id}")
        expect(membership_of(person).role).to eq('administrator')
        expect(person.reload.attributes.slice('encrypted_password', 'name', 'confirmed_at')).to eq(before)
      end

      it 'says so when the person is in the account already' do
        create(:account_user, account: account, user: person, role: :administrator)

        add_user(new_person(email: 'erbol@example.test', adopt: '1'))

        expect(error_for('user')).to eq('Ербол Туран уже состоит в этом аккаунте: администратор.')
      end
    end
  end

  describe 'one transaction' do
    it 'adds nobody when the membership cannot be saved: the new user is not left behind' do
      allow(AccountUser).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect { add_user(new_person) }.not_to(change { [User.count, AccountUser.count] })

      expect(response).to have_http_status(:unprocessable_content)
      expect(page.at_css('[data-testid="add-user-errors"]').text).to include('ничего не сохранено')
      expect(Audited::Audit.where(action: 'add_user')).to be_empty
    end
  end

  describe 'the form of the user card (an existing user into an account)' do
    it 'says in red, not in the green banner, that the user is in the account already' do
      user = create(:user, account: account, role: :agent)

      post '/super_admin/account_users', params: { account_user: { account_id: account.id, user_id: user.id, role: 'agent' } }

      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to be_present
    end

    it 'still says it worked when it did' do
      user = create(:user)

      post '/super_admin/account_users', params: { account_user: { account_id: account.id, user_id: user.id, role: 'agent' } }

      expect(flash[:notice]).to eq('Пользователь добавлен в аккаунт.')
      expect(flash[:alert]).to be_nil
    end
  end
end
