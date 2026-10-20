require 'rails_helper'

# «Сбросить двухфакторный вход» on the card of a user: the person lost the phone, so the second factor is taken off.
RSpec.describe 'Super Admin reset of the second factor of a user', type: :request do
  let(:super_admin) { create(:super_admin) }
  let!(:person) { create(:user, name: 'Мерей Оператор', otp_required_for_login: true) }

  before { sign_in(super_admin, scope: :super_admin) }

  def page = Nokogiri::HTML(response.body)

  def text(node) = node.text.squish

  def audits = Audited::Audit.where(auditable_type: 'User', auditable_id: person.id, action: 'reset_two_factor')

  describe 'the card of the user' do
    it 'offers the reset to a person who has the second factor, with the question and what happens' do
      get "/super_admin/users/#{person.id}"

      node = page.at_css('[data-testid="confirm-reset-two-factor"]')
      expect(text(node.at_css('summary'))).to eq('Сбросить двухфакторный вход')
      expect(text(node.at_css('.admin-ask__title'))).to eq('Сбросить двухфакторный вход у «Мерей Оператор»?')
      expect(text(node.at_css('.admin-ask__panel'))).to include('войдёт по паролю', 'включить двухфакторный вход заново', 'журнал аудита')
      expect(node.at_css('form')['action']).to eq("/super_admin/users/#{person.id}/reset_two_factor")
      expect(text(node.at_css('button[type="submit"]'))).to eq('Да, сбросить')
    end

    it 'does not offer it when the person has no second factor' do
      person.update!(otp_required_for_login: false)

      get "/super_admin/users/#{person.id}"

      expect(page.at_css('[data-testid="confirm-reset-two-factor"]')).to be_nil
    end

    it 'does not offer it on your own card' do
      own = create(:super_admin, otp_required_for_login: true)
      sign_in(own, scope: :super_admin)

      get "/super_admin/users/#{own.id}"

      expect(page.at_css('[data-testid="confirm-reset-two-factor"]')).to be_nil
    end
  end

  describe 'POST /super_admin/users/:id/reset_two_factor' do
    it 'takes the second factor off: the person signs in with the password and can switch it on again' do
      post "/super_admin/users/#{person.id}/reset_two_factor"

      expect(response).to redirect_to("/super_admin/users/#{person.id}")
      expect(flash[:notice]).to eq('Двухфакторный вход у «Мерей Оператор» сброшен: он входит по паролю и может включить защиту заново.')
      person.reload
      expect(person.otp_required_for_login).to be(false)
      expect(person.otp_secret).to be_nil
      expect(person.otp_backup_codes).to be_blank
      expect(person).not_to be_mfa_enabled
    end

    it 'takes the secret and the backup codes away as well where the installation keeps them' do
      skip('Skipping since MFA is not configured in this environment') unless Chatwoot.encryption_configured?
      person.enable_two_factor!
      person.generate_backup_codes!

      post "/super_admin/users/#{person.id}/reset_two_factor"

      expect(person.reload.otp_secret).to be_nil
      expect(person.otp_backup_codes).to be_blank
      expect(person.backup_codes_generated?).to be(false)
    end

    it 'keeps the password, the e-mail and the accounts of the person' do
      account = create(:account)
      create(:account_user, account: account, user: person, role: :agent)
      encrypted = person.encrypted_password

      post "/super_admin/users/#{person.id}/reset_two_factor"

      person.reload
      expect(person.encrypted_password).to eq(encrypted)
      expect(person.accounts).to eq([account])
    end

    it 'writes who did it, and not the secret or the codes, to the audit log' do
      post "/super_admin/users/#{person.id}/reset_two_factor"

      expect(audits.count).to eq(1)
      audit = audits.last
      expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin')
      expect(audit.audited_changes).to eq('two_factor' => %w[enabled disabled], 'email' => person.email)
    end

    it 'shows the card again with the state «выключена» afterwards' do
      post "/super_admin/users/#{person.id}/reset_two_factor"
      get "/super_admin/users/#{person.id}"

      expect(text(page.at_css('#mfa_enabled + dd'))).to include('Выключена')
      expect(page.at_css('[data-testid="confirm-reset-two-factor"]')).to be_nil
    end

    it 'says so, and writes nothing, for a person who has no second factor' do
      person.update!(otp_required_for_login: false)

      post "/super_admin/users/#{person.id}/reset_two_factor"

      expect(flash[:alert]).to eq('У этого пользователя двухфакторный вход не включён.')
      expect(audits).to be_empty
    end

    it 'refuses your own sign-in: that is changed in the operator app, where the code is asked first' do
      own = create(:super_admin, otp_required_for_login: true)
      sign_in(own, scope: :super_admin)

      post "/super_admin/users/#{own.id}/reset_two_factor"

      expect(flash[:alert]).to include('Свой двухфакторный вход сбрасывается в кабинете оператора')
      expect(own.reload.otp_required_for_login).to be(true)
      expect(Audited::Audit.where(action: 'reset_two_factor')).to be_empty
    end

    it 'can reset the second factor of another super admin' do
      other = create(:super_admin, otp_required_for_login: true)

      post "/super_admin/users/#{other.id}/reset_two_factor"

      expect(other.reload.otp_required_for_login).to be(false)
    end

    it 'is not open to a visitor who has not signed in' do
      sign_out(:super_admin)

      post "/super_admin/users/#{person.id}/reset_two_factor"

      expect(response).to have_http_status(:redirect)
      expect(person.reload.otp_required_for_login).to be(true)
    end

    it 'names the entry in Russian in the audit log page' do
      post "/super_admin/users/#{person.id}/reset_two_factor"

      get '/super_admin/audits', params: { audit_action: 'reset_two_factor' }

      expect(page.css('tbody .admin-badge').map { |badge| text(badge) }).to include('Сброс двухфакторного входа')
    end
  end
end
