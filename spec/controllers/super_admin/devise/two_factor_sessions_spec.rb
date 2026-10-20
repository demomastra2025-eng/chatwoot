require 'rails_helper'

# The sign-in of the super admin: password, a second step when the user has two-factor authentication on, and an entry
# of the audit log for every sign-in, failed attempt, wrong code and sign-out.
RSpec.describe 'Super Admin sign-in with two-factor authentication', type: :request do
  let(:password) { 'Password1!' }
  let!(:super_admin) { create(:super_admin, password: password) }
  let(:page) { Nokogiri::HTML(response.body) }
  let(:attempts_key) { format(Redis::RedisKeys::SUPER_ADMIN_TWO_FACTOR_ATTEMPTS, super_admin_id: super_admin.id) }
  let(:session_cookie) { Rails.application.config.session_options[:key] }
  let(:too_many) { 'Слишком много неверных кодов. Второй шаг закрыт на 15 мин.: войдите снова позже.' }

  # The count of codes lives in Redis, which no example rolls back
  before { Redis::Alfred.delete(attempts_key) }

  after { Redis::Alfred.delete(attempts_key) }

  def sign_in_with_password(email: super_admin.email, password: self.password)
    post '/super_admin/sign_in', params: { super_admin: { email: email, password: password } }
  end

  def signed_in?
    get '/super_admin/audits'
    response.status == 200
  end

  def audits(action) = Audited::Audit.where(action: action).order(:id)

  def accept_codes(accepted)
    allow(Mfa::AuthenticationService).to receive(:new).and_return(instance_double(Mfa::AuthenticationService, authenticate: accepted))
  end

  describe 'a super admin without two-factor authentication' do
    it 'signs in with the password alone and the entry says who did it' do
      sign_in_with_password

      expect(response).to redirect_to('/super_admin')
      expect(signed_in?).to be(true)
      audit = audits('super_admin_login').last
      expect(audit).to have_attributes(auditable_id: super_admin.id, user_id: super_admin.id, comment: 'super_admin')
      expect(audit.audited_changes).to eq({})
    end

    it 'signs out with an entry in the audit log' do
      sign_in_with_password

      get '/super_admin/logout'

      expect(response).to redirect_to('/')
      expect(signed_in?).to be(false)
      expect(audits('super_admin_logout').last).to have_attributes(auditable_id: super_admin.id, user_id: super_admin.id)
    end

    it 'writes nothing for a sign-out of nobody' do
      get '/super_admin/logout'

      expect(audits('super_admin_logout')).to be_empty
    end
  end

  describe 'a wrong password or an unknown e-mail' do
    it 'refuses with the same words and records the attempt on the super admin' do
      sign_in_with_password(password: 'nope')

      expect(response).to redirect_to('/super_admin/sign_in')
      expect(flash[:error]).to include('email')
      expect(signed_in?).to be(false)
      audit = audits('super_admin_login_failed').last
      expect(audit).to have_attributes(auditable_id: super_admin.id, user_id: nil)
      expect(audit.audited_changes).to eq('reason' => 'wrong_password')
    end

    it 'records an unknown e-mail by the typed e-mail, without a password, on nobody' do
      sign_in_with_password(email: 'Nobody@Example.com', password: 'secret-typed-by-mistake')

      expect(flash[:error]).to include('email')
      audit = audits('super_admin_login_failed').last
      expect(audit).to have_attributes(auditable_id: nil, auditable_type: nil, username: 'nobody@example.com')
      expect(audit.audited_changes).to eq('reason' => 'unknown_email')
      expect(Audited::Audit.all.map { |row| row.attributes.values.join(' ') }.join).not_to include('secret-typed-by-mistake')
    end

    it 'keeps what was typed into the e-mail field only when it looks like an e-mail, so a password typed there is not kept' do
      sign_in_with_password(email: 'My-Secret-Pass1!', password: 'whatever')

      audit = audits('super_admin_login_failed').last
      expect(audit).to have_attributes(auditable_id: nil, user_id: nil, username: nil, comment: 'system')
      expect(audit.audited_changes).to eq('reason' => 'unknown_email', 'typed' => 'not_an_email')
      expect(Audited::Audit.all.map { |row| row.attributes.values.join(' ') }.join).not_to include('My-Secret-Pass1!')
    end

    it 'does not sign in an ordinary user of the operator app' do
      create(:user, email: 'operator@example.com', password: password)

      sign_in_with_password(email: 'operator@example.com')

      expect(signed_in?).to be(false)
      expect(audits('super_admin_login_failed').last.audited_changes).to eq('reason' => 'unknown_email')
    end

    it 'cuts a very long typed e-mail in the entry' do
      sign_in_with_password(email: "#{'a' * 500}@example.com")

      expect(audits('super_admin_login_failed').last.username.length).to eq(SuperAdmin::PlatformAudit::USERNAME_LIMIT)
    end
  end

  describe 'a super admin with two-factor authentication' do
    before { super_admin.update!(otp_required_for_login: true) }

    it 'asks for the second step after the password and does not sign in yet' do
      sign_in_with_password

      expect(response).to redirect_to('/super_admin/sign_in/two_factor')
      expect(signed_in?).to be(false)
      expect(audits('super_admin_login')).to be_empty
    end

    it 'does not ask for the second step when the password is wrong' do
      sign_in_with_password(password: 'nope')

      expect(response).to redirect_to('/super_admin/sign_in')
      get '/super_admin/sign_in/two_factor'
      expect(response).to redirect_to('/super_admin/sign_in')
    end

    it 'shows the page of the second step in Russian, for the e-mail that was checked' do
      sign_in_with_password
      get '/super_admin/sign_in/two_factor'

      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1').text).to eq('Второй шаг входа')
      expect(page.text).to include(super_admin.email, 'Код из приложения', 'Резервный код', 'Подтвердить и войти')
      expect(page.at_css('input[name="otp_code"][autocomplete="one-time-code"]')).to be_present
      expect(page.at_css('input[name="backup_code"]')).to be_present
      expect(response.body).not_to include('translation missing')
    end

    it 'has no page of the second step without the password' do
      get '/super_admin/sign_in/two_factor'

      expect(response).to redirect_to('/super_admin/sign_in')
      expect(flash[:error]).to eq('Время второго шага вышло. Войдите заново.')
    end

    it 'does not accept a code without the password step' do
      accept_codes(true)

      post '/super_admin/sign_in/two_factor', params: { otp_code: '123456' }

      expect(response).to redirect_to('/super_admin/sign_in')
      expect(signed_in?).to be(false)
    end

    it 'signs in with a right code and the entry says that the code came from the authenticator' do
      sign_in_with_password
      accept_codes(true)

      post '/super_admin/sign_in/two_factor', params: { otp_code: '123 456' }

      expect(response).to redirect_to('/super_admin')
      expect(signed_in?).to be(true)
      expect(audits('super_admin_login').last).to have_attributes(auditable_id: super_admin.id, user_id: super_admin.id)
      expect(audits('super_admin_login').last.audited_changes).to eq('second_factor' => 'authenticator')
    end

    it 'passes the digits without spaces to the check' do
      sign_in_with_password
      service = instance_double(Mfa::AuthenticationService, authenticate: true)
      expect(Mfa::AuthenticationService).to receive(:new).with(user: super_admin, otp_code: '123456', backup_code: nil).and_return(service)

      post '/super_admin/sign_in/two_factor', params: { otp_code: ' 123 456 ' }
    end

    it 'signs in with a backup code and the entry says so' do
      sign_in_with_password
      service = instance_double(Mfa::AuthenticationService, authenticate: true)
      expect(Mfa::AuthenticationService).to receive(:new).with(user: super_admin, otp_code: nil, backup_code: 'A1B2C3D4').and_return(service)

      post '/super_admin/sign_in/two_factor', params: { backup_code: 'a1b2 c3d4' }

      expect(response).to redirect_to('/super_admin')
      expect(audits('super_admin_login').last.audited_changes).to eq('second_factor' => 'backup_code')
    end

    it 'refuses a wrong code, keeps the second step open and records the wrong code' do
      sign_in_with_password
      accept_codes(false)

      post '/super_admin/sign_in/two_factor', params: { otp_code: '000000' }

      expect(response).to redirect_to('/super_admin/sign_in/two_factor')
      expect(flash[:error]).to eq('Неверный код. Проверьте код и попробуйте ещё раз.')
      expect(signed_in?).to be(false)
      audit = audits('super_admin_two_factor_failed').last
      expect(audit).to have_attributes(auditable_id: super_admin.id)
      expect(audit.audited_changes).to eq('wrong_codes' => 1)
      expect(audits('super_admin_login')).to be_empty
    end

    it 'refuses an empty code without asking the check at all' do
      sign_in_with_password
      expect(Mfa::AuthenticationService).not_to receive(:new)

      post '/super_admin/sign_in/two_factor', params: { otp_code: '', backup_code: '' }

      expect(flash[:error]).to eq('Неверный код. Проверьте код и попробуйте ещё раз.')
    end

    it 'closes the second step after five wrong codes, even for the right code that follows' do
      sign_in_with_password
      accept_codes(false)

      5.times { post '/super_admin/sign_in/two_factor', params: { otp_code: '000000' } }

      expect(response).to redirect_to('/super_admin/sign_in')
      expect(flash[:error]).to eq(too_many)
      expect(audits('super_admin_two_factor_failed').map { |audit| audit.audited_changes['wrong_codes'] }).to eq([1, 2, 3, 4, 5])

      accept_codes(true)
      post '/super_admin/sign_in/two_factor', params: { otp_code: '123456' }
      expect(response).to redirect_to('/super_admin/sign_in')
      expect(signed_in?).to be(false)
    end

    # The cookie of the password step can be sent again as it was issued: a count kept in it would start from zero
    it 'counts the wrong codes on the server, so sending the cookie of the password step again does not reopen the step' do
      sign_in_with_password
      issued = cookies[session_cookie]
      service = instance_double(Mfa::AuthenticationService, authenticate: false)
      allow(Mfa::AuthenticationService).to receive(:new).and_return(service)

      8.times do
        cookies[session_cookie] = issued
        post '/super_admin/sign_in/two_factor', params: { otp_code: '000000' }
      end

      expect(response).to redirect_to('/super_admin/sign_in')
      expect(flash[:error]).to eq(too_many)
      expect(Mfa::AuthenticationService).to have_received(:new).exactly(5).times
      expect(audits('super_admin_two_factor_failed').map { |audit| audit.audited_changes['wrong_codes'] }).to eq([1, 2, 3, 4, 5])

      accept_codes(true)
      cookies[session_cookie] = issued
      post '/super_admin/sign_in/two_factor', params: { otp_code: '123456' }
      expect(response).to redirect_to('/super_admin/sign_in')
      expect(signed_in?).to be(false)
    end

    it 'keeps the step closed when the password is entered again, and does not touch another super admin' do
      other = create(:super_admin, password: password)
      other.update!(otp_required_for_login: true)
      sign_in_with_password
      accept_codes(false)
      5.times { post '/super_admin/sign_in/two_factor', params: { otp_code: '000000' } }

      sign_in_with_password
      expect(response).to redirect_to('/super_admin/sign_in')
      expect(flash[:error]).to eq(too_many)
      get '/super_admin/sign_in/two_factor'
      expect(response).to redirect_to('/super_admin/sign_in')

      sign_in_with_password(email: other.email)
      expect(response).to redirect_to('/super_admin/sign_in/two_factor')
    end

    it 'opens the step again when the time of the lock is over' do
      sign_in_with_password
      accept_codes(false)
      5.times { post '/super_admin/sign_in/two_factor', params: { otp_code: '000000' } }
      expect($alfred.with { |redis| redis.ttl(attempts_key) }).to be_between(1, 15.minutes.to_i) # rubocop:disable Style/GlobalVars

      Redis::Alfred.delete(attempts_key) # what the expiry of the key does
      sign_in_with_password
      accept_codes(true)
      post '/super_admin/sign_in/two_factor', params: { otp_code: '123456' }

      expect(response).to redirect_to('/super_admin')
      expect(signed_in?).to be(true)
    end

    it 'forgets the wrong codes of a super admin who then enters a right one' do
      sign_in_with_password
      accept_codes(false)
      3.times { post '/super_admin/sign_in/two_factor', params: { otp_code: '000000' } }
      expect(Redis::Alfred.get(attempts_key).to_i).to eq(3)

      accept_codes(true)
      post '/super_admin/sign_in/two_factor', params: { otp_code: '123456' }

      expect(signed_in?).to be(true)
      expect(Redis::Alfred.get(attempts_key)).to be_nil
    end

    it 'closes the second step when the time is over' do
      sign_in_with_password
      accept_codes(true)

      travel_to(6.minutes.from_now) do
        post '/super_admin/sign_in/two_factor', params: { otp_code: '123456' }

        expect(response).to redirect_to('/super_admin/sign_in')
        expect(flash[:error]).to eq('Время второго шага вышло. Войдите заново.')
        expect(signed_in?).to be(false)
      end
    end

    it 'does not accept a code when the check itself breaks, for example without the encryption keys' do
      sign_in_with_password
      allow(Mfa::AuthenticationService).to receive(:new).and_raise(ActiveRecord::Encryption::Errors::Configuration, 'no keys')

      post '/super_admin/sign_in/two_factor', params: { otp_code: '123456' }

      expect(flash[:error]).to eq('Неверный код. Проверьте код и попробуйте ещё раз.')
      expect(signed_in?).to be(false)
    end

    it 'lets a super admin without the second step sign in while this one needs it' do
      other = create(:super_admin, password: password)

      sign_in_with_password(email: other.email)

      expect(response).to redirect_to('/super_admin')
    end
  end

  describe 'with real codes', if: Chatwoot.encryption_configured? do
    let(:secret) { User.generate_otp_secret }

    before do
      super_admin.update!(otp_secret: secret, otp_required_for_login: true)
      super_admin.generate_backup_codes!
    end

    it 'signs in with the code of the authenticator app and not with an old or wrong one' do
      sign_in_with_password
      post '/super_admin/sign_in/two_factor', params: { otp_code: '000000' }
      expect(signed_in?).to be(false)

      post '/super_admin/sign_in/two_factor', params: { otp_code: ROTP::TOTP.new(secret).now }

      expect(response).to redirect_to('/super_admin')
      expect(signed_in?).to be(true)
    end

    it 'signs in with a backup code once' do
      code = super_admin.reload.otp_backup_codes.first
      sign_in_with_password

      post '/super_admin/sign_in/two_factor', params: { backup_code: code }
      expect(response).to redirect_to('/super_admin')

      get '/super_admin/logout'
      sign_in_with_password
      post '/super_admin/sign_in/two_factor', params: { backup_code: code }
      expect(response).to redirect_to('/super_admin/sign_in/two_factor')
      expect(signed_in?).to be(false)
    end
  end

  # Other ways to a signed-in super admin must not skip the second step or let a stranger become a super admin
  describe 'the other Devise routes of a super admin' do
    it 'has no sign-up: a super admin is never created by the person himself' do
      routes = Rails.application.routes

      expect { routes.recognize_path('/super_admin', method: 'POST') }.to raise_error(ActionController::RoutingError)
      expect { routes.recognize_path('/super_admin/sign_up', method: 'GET') }.to raise_error(ActionController::RoutingError)
    end

    it 'does not sign a super admin in after a password reset, so the second step cannot be skipped' do
      super_admin.update!(otp_required_for_login: true)
      token = super_admin.send_reset_password_instructions

      patch '/super_admin/password',
            params: { super_admin: { reset_password_token: token, password: 'NewPassword1!', password_confirmation: 'NewPassword1!' } }

      expect(response).to redirect_to('/super_admin/sign_in')
      expect(super_admin.reload.valid_password?('NewPassword1!')).to be(true)
      expect(signed_in?).to be(false)
    end

    it 'asks for the second step after the reset, with the new password' do
      super_admin.update!(otp_required_for_login: true)
      token = super_admin.send_reset_password_instructions
      patch '/super_admin/password',
            params: { super_admin: { reset_password_token: token, password: 'NewPassword1!', password_confirmation: 'NewPassword1!' } }

      sign_in_with_password(password: 'NewPassword1!')

      expect(response).to redirect_to('/super_admin/sign_in/two_factor')
    end
  end

  describe 'the notice on «Сводка»' do
    before { sign_in(super_admin, scope: :super_admin) }

    # Not memoized: some examples open several pages in a row
    def page = Nokogiri::HTML(response.body)

    def notice = page.at_css('[data-testid="two-factor-notice"]')

    it 'tells a super admin without two-factor authentication where to turn it on, and opens that page' do
      allow(Chatwoot).to receive(:mfa_enabled?).and_return(true)
      account = create(:account)
      create(:account_user, user: super_admin, account: account)

      get '/super_admin'

      expect(notice.at_css('h2').text.squish).to eq('Двухфакторная защита выключена')
      expect(notice.at_css('[data-testid="two-factor-notice-steps"]').text)
        .to include('«Настройки профиля» → «Безопасность» → «Управление двухфакторной аутентификацией»')
      expect(notice.text).not_to include('«Профиль»')
      expect(notice.at_css('[data-testid="two-factor-notice-enable"]')['href']).to eq("/app/accounts/#{account.id}/profile/mfa")
      expect(notice.at_css('[data-testid="two-factor-notice-enable"]').text.squish).to eq('Включить двухфакторный вход')
    end

    it 'opens the page in the first account of the super admin' do
      allow(Chatwoot).to receive(:mfa_enabled?).and_return(true)
      first = create(:account)
      second = create(:account)
      create(:account_user, user: super_admin, account: second)
      create(:account_user, user: super_admin, account: first)

      get '/super_admin'

      expect(notice.at_css('[data-testid="two-factor-notice-enable"]')['href']).to eq("/app/accounts/#{first.id}/profile/mfa")
    end

    it 'tells a super admin who is in no account that the profile needs one, and links to his user card' do
      allow(Chatwoot).to receive(:mfa_enabled?).and_return(true)

      get '/super_admin'

      expect(notice.at_css('[data-testid="two-factor-notice-no-account"]').text).to include('не состоит ни в одном', 'Добавить в аккаунт')
      expect(notice.css('a').map { |link| link['href'] }).to eq(["/super_admin/users/#{super_admin.id}"])
    end

    it 'says that it cannot be turned on yet when the server has no encryption keys, and folds the names of the settings' do
      allow(Chatwoot).to receive(:mfa_enabled?).and_return(false)

      get '/super_admin'

      expect(notice.text).to include('не заданы ключи шифрования', 'её делает разработчик')
      expect(notice.text).not_to include('администратору сервера')
      expect(notice.at_css('a')).to be_nil
      developer = notice.at_css('[data-testid="two-factor-notice-developer"]')
      expect(developer.at_css('summary').text.squish).to eq('Для разработчика')
      expect(developer.text).to include('ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY')
    end

    it 'is not there for a super admin who has it on' do
      super_admin.update!(otp_required_for_login: true)

      get '/super_admin'

      expect(response).to have_http_status(:ok)
      expect(notice).to be_nil
    end

    describe '«Больше не показывать»' do
      let(:other) { create(:super_admin) }

      before { allow(Chatwoot).to receive(:mfa_enabled?).and_return(true) }

      it 'is a button under the notice' do
        get '/super_admin'

        form = notice.at_css('form')
        expect(form['action']).to eq('/super_admin/two_factor_notice/hide')
        expect(form['method']).to eq('post')
        expect(form.at_css('button').text.squish).to eq('Больше не показывать')
      end

      it 'hides the notice for this super admin and says how to bring it back' do
        post '/super_admin/two_factor_notice/hide'

        expect(response).to redirect_to('/super_admin')
        follow_redirect!
        expect(notice).to be_nil
        expect(page.text.squish).to include('Напоминание скрыто', 'Вернуть напоминание можно на своей карточке пользователя')
        expect(SuperAdmin::TwoFactorNotice.hidden?(super_admin.reload)).to be(true)
      end

      it 'leaves the notice of another super admin as it was' do
        post '/super_admin/two_factor_notice/hide'
        sign_out(:super_admin)
        sign_in(other, scope: :super_admin)

        get '/super_admin'

        expect(notice).to be_present
      end

      it 'keeps what else the user keeps in his attributes' do
        super_admin.update!(custom_attributes: { 'note' => 'keep me' })

        post '/super_admin/two_factor_notice/hide'

        expect(super_admin.reload.custom_attributes).to include('note' => 'keep me', SuperAdmin::TwoFactorNotice::KEY => be_present)
      end

      it 'leaves an entry of the audit log' do
        expect { post '/super_admin/two_factor_notice/hide' }.to change { Audited::Audit.where(action: 'hide_two_factor_notice').count }.by(1)

        expect(Audited::Audit.find_by(action: 'hide_two_factor_notice'))
          .to have_attributes(auditable_id: super_admin.id, user_id: super_admin.id, comment: 'super_admin')
      end

      it 'is brought back on the card of the user, with an entry of the audit log' do
        post '/super_admin/two_factor_notice/hide'

        get "/super_admin/users/#{super_admin.id}"
        hidden = page.at_css('[data-testid="two-factor-notice-hidden"]')
        expect(hidden.text.squish).to include('Напоминание на «Сводке» скрыто', 'Показывать снова')
        expect(hidden.at_css('form')['action']).to eq('/super_admin/two_factor_notice/restore')

        expect { post '/super_admin/two_factor_notice/restore', headers: { 'HTTP_REFERER' => "http://www.example.com/super_admin/users/#{super_admin.id}" } }
          .to change { Audited::Audit.where(action: 'show_two_factor_notice').count }.by(1)
        expect(response).to redirect_to("/super_admin/users/#{super_admin.id}")

        get '/super_admin'
        expect(notice).to be_present
        expect(SuperAdmin::TwoFactorNotice.hidden?(super_admin.reload)).to be(false)
      end

      it 'does not offer the way back on the card of another user or when nothing is hidden' do
        get "/super_admin/users/#{super_admin.id}"
        expect(page.at_css('[data-testid="two-factor-notice-hidden"]')).to be_nil

        post '/super_admin/two_factor_notice/hide'
        get "/super_admin/users/#{other.id}"
        expect(page.at_css('[data-testid="two-factor-notice-hidden"]')).to be_nil
      end

      it 'needs a sign-in' do
        sign_out(:super_admin)

        post '/super_admin/two_factor_notice/hide'

        expect(response).to have_http_status(:redirect)
        expect(response.location).to include('/super_admin/sign_in')
        expect(SuperAdmin::TwoFactorNotice.hidden?(super_admin.reload)).to be(false)
      end
    end
  end
end
