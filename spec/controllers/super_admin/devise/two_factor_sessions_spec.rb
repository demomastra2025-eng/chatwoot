require 'rails_helper'

# The sign-in of the super admin: password, a second step when the user has two-factor authentication on, and an entry
# of the audit log for every sign-in, failed attempt, wrong code and sign-out.
RSpec.describe 'Super Admin sign-in with two-factor authentication', type: :request do
  let(:password) { 'Password1!' }
  let!(:super_admin) { create(:super_admin, password: password) }
  let(:page) { Nokogiri::HTML(response.body) }

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
      expect(flash[:error]).to eq('Слишком много неверных кодов. Войдите заново.')
      expect(audits('super_admin_two_factor_failed').map { |audit| audit.audited_changes['wrong_codes'] }).to eq([1, 2, 3, 4, 5])

      accept_codes(true)
      post '/super_admin/sign_in/two_factor', params: { otp_code: '123456' }
      expect(response).to redirect_to('/super_admin/sign_in')
      expect(signed_in?).to be(false)
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

  describe 'the notice on «Сводка»' do
    before { sign_in(super_admin, scope: :super_admin) }

    def notice = page.at_css('[data-testid="two-factor-notice"]')

    it 'tells a super admin without two-factor authentication where to turn it on' do
      allow(Chatwoot).to receive(:mfa_enabled?).and_return(true)

      get '/super_admin'

      expect(notice.at_css('h2').text.squish).to eq('Двухфакторная защита выключена')
      expect(notice.text).to include('«Профиль» → «Безопасность» → «Управление двухфакторной аутентификацией»')
      expect(notice.at_css('a')['href']).to eq('/app')
    end

    it 'says that it cannot be turned on yet when the server has no encryption keys' do
      allow(Chatwoot).to receive(:mfa_enabled?).and_return(false)

      get '/super_admin'

      expect(notice.text).to include('не заданы ключи шифрования')
      expect(notice.at_css('a')).to be_nil
    end

    it 'is not there for a super admin who has it on' do
      super_admin.update!(otp_required_for_login: true)

      get '/super_admin'

      expect(response).to have_http_status(:ok)
      expect(notice).to be_nil
    end
  end
end
