require 'rails_helper'

RSpec.describe 'Super Admin Users API', type: :request do
  let(:super_admin) { create(:super_admin) }

  describe 'GET /super_admin/users' do
    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        get '/super_admin/users'
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'when it is an authenticated super admin' do
      let!(:user) { create(:user, name: 'Disabled User') }
      let!(:params) do
        { user: {
          name: 'admin@example.com',
          display_name: 'admin@example.com',
          email: 'admin@example.com',
          password: 'Password1!',
          confirmed_at: '2023-03-20 22:32:41',
          type: 'SuperAdmin',
          super_admin_confirmation: 'admin@example.com'
        } }
      end
      let!(:params_without_confirmed_at) do
        { user: {
          name: 'agent@example.com',
          display_name: 'agent@example.com',
          email: 'agent@example.com',
          password: 'Password1!',
          type: 'SuperAdmin',
          super_admin_confirmation: 'agent@example.com'
        } }
      end
      let!(:params_with_blank_confirmed_at) do
        { user: {
          name: 'agent-2@example.com',
          display_name: 'agent-2@example.com',
          email: 'agent-2@example.com',
          password: 'Password1!',
          confirmed_at: '',
          type: 'SuperAdmin',
          super_admin_confirmation: 'agent-2@example.com'
        } }
      end

      it 'shows the list of users' do
        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/users'
        doc = Nokogiri::HTML(response.body)
        header_texts = doc.css('table thead th').map { |header| header.text.squish }

        expect(response).to have_http_status(:success)
        expect(doc.at_css('a[href="/super_admin/users/new"]')).to be_present
        expect(response.body).to include(CGI.escapeHTML(user.name))
        expect(header_texts).not_to include('MFA')
      end

      it 'prefills confirmed_at on new user form' do
        sign_in(super_admin, scope: :super_admin)
        get '/super_admin/users/new'

        expect(response).to have_http_status(:success)
        expect(response.body).to include('name="user[confirmed_at]"')
        confirmed_at_value = response.body[/name="user\[confirmed_at\]".*?value="([^"]+)"/m, 1]
        expect(confirmed_at_value).to be_present
      end

      it 'creates the new super_admin record' do
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/users', params: params

        expect(response).to redirect_to("http://www.example.com/super_admin/users/#{User.last.id}")
        expect(SuperAdmin.last.email).to eq('admin@example.com')

        post '/super_admin/users', params: params
        expect(response).to redirect_to('http://www.example.com/super_admin/users/new')
      end

      it 'uses the display name when the name is left blank' do
        sign_in(super_admin, scope: :super_admin)

        expect do
          post '/super_admin/users', params: { user: { name: '', display_name: 'Асем', email: 'asem@example.com', password: 'Password1!' } }
        end.to change(User, :count).by(1)

        expect(response).to redirect_to("http://www.example.com/super_admin/users/#{User.last.id}")
        expect(User.last).to have_attributes(name: 'Асем', display_name: 'Асем', email: 'asem@example.com')
      end

      it 'uses the email local part when both the name and the display name are blank' do
        sign_in(super_admin, scope: :super_admin)

        expect do
          post '/super_admin/users', params: { user: { name: '', display_name: '', email: 'new.agent@example.com', password: 'Password1!' } }
        end.to change(User, :count).by(1)

        expect(response).to redirect_to("http://www.example.com/super_admin/users/#{User.last.id}")
        expect(User.last).to have_attributes(name: 'new.agent', email: 'new.agent@example.com')
      end

      it 'fills the name when the name field is not submitted at all' do
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/users', params: { user: { display_name: 'Только имя', email: 'only-display@example.com', password: 'Password1!' } }

        expect(response).to redirect_to("http://www.example.com/super_admin/users/#{User.last.id}")
        expect(User.last.name).to eq('Только имя')
      end

      it 'keeps an explicitly provided name' do
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/users', params: { user: { name: 'Full Name', display_name: 'Short', email: 'named@example.com', password: 'Password1!' } }

        expect(User.last).to have_attributes(name: 'Full Name', display_name: 'Short')
      end

      it 'answers with a validation notice instead of a server error when nothing usable is submitted' do
        sign_in(super_admin, scope: :super_admin)

        expect do
          post '/super_admin/users', params: { user: { name: '', display_name: '', email: '', password: 'Password1!' } }
        end.not_to change(User, :count)

        expect(response).to redirect_to('http://www.example.com/super_admin/users/new')
      end

      it 'creates unconfirmed users when confirmed_at is not provided in payload' do
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/users', params: params_without_confirmed_at

        expect(response).to redirect_to("http://www.example.com/super_admin/users/#{User.last.id}")
        expect(User.last).not_to be_confirmed
      end

      it 'creates unconfirmed users when confirmed_at is explicitly cleared' do
        sign_in(super_admin, scope: :super_admin)

        post '/super_admin/users', params: params_with_blank_confirmed_at

        expect(response).to redirect_to("http://www.example.com/super_admin/users/#{User.last.id}")
        expect(User.last).not_to be_confirmed
      end
    end
  end

  describe 'DELETE /super_admin/users/:id/avatar' do
    let!(:user) { create(:user, :with_avatar) }

    context 'when it is an unauthenticated super admin' do
      it 'returns unauthorized' do
        delete "/super_admin/users/#{user.id}/avatar", params: { attachment_id: user.avatar.id }
        expect(response).to have_http_status(:redirect)
        expect(user.reload.avatar).to be_attached
      end
    end

    context 'when it is an authenticated super admin' do
      it 'destroys the avatar' do
        sign_in(super_admin, scope: :super_admin)
        delete "/super_admin/users/#{user.id}/avatar", params: { attachment_id: user.avatar.id }
        expect(response).to have_http_status(:redirect)
        expect(user.reload.avatar).not_to be_attached
      end
    end
  end

  describe 'PATCH /super_admin/users/:id' do
    let!(:user) { create(:user) }
    let(:request_path) { "/super_admin/users/#{user.id}" }

    before { sign_in(super_admin, scope: :super_admin) }

    it 'skips reconfirmation when confirmed_at is provided' do
      expect do
        patch request_path, params: { user: { email: 'updated@example.com', confirmed_at: Time.current } }
      end.not_to have_enqueued_mail(Devise::Mailer, :confirmation_instructions)

      expect(response).to have_http_status(:redirect)
      expect(user.reload.email).to eq('updated@example.com')
      expect(user.reload.unconfirmed_email).to be_nil
    end

    it 'leaves the name untouched when it is not submitted' do
      original_name = user.name

      patch request_path, params: { user: { display_name: 'Another display name' } }

      expect(response).to have_http_status(:redirect)
      expect(user.reload).to have_attributes(name: original_name, display_name: 'Another display name')
    end

    it 'falls back to the display name when the name is cleared' do
      patch request_path, params: { user: { name: '', display_name: 'Cleared name fallback' } }

      expect(response).to have_http_status(:redirect)
      expect(user.reload.name).to eq('Cleared name fallback')
    end

    it 'does not skip reconfirmation when confirmed_at is blank' do
      original_email = user.email
      expect do
        patch request_path, params: { user: { email: 'updated-again@example.com' } }
      end.to have_enqueued_mail(Devise::Mailer, :confirmation_instructions)

      expect(response).to have_http_status(:redirect)
      expect(user.reload.unconfirmed_email).to eq('updated-again@example.com')
      expect(user.email).to eq(original_email)
    end
  end

  describe 'GET /super_admin/users/:id' do
    let!(:user) { create(:user, name: 'MFA Enabled User', otp_required_for_login: true) }

    it 'shows the two-factor state on the user detail page, in Russian' do
      sign_in(super_admin, scope: :super_admin)

      get "/super_admin/users/#{user.id}"
      doc = Nokogiri::HTML(response.body)
      labels = doc.css('dt.attribute-label').map { |label| label.text.squish }

      expect(response).to have_http_status(:success)
      expect(labels).to include('Двухфакторная аутентификация')
      expect(doc.at_css('#mfa_enabled + dd').text.squish).to include('Включена')
      expect(response.body).to include(CGI.escapeHTML(user.name))
    end

    context 'when the user belongs to accounts' do
      let!(:first_account) { create(:account, name: 'First Impersonation Account') }
      let!(:second_account) { create(:account, name: 'Second Impersonation Account') }

      before do
        create(:account_user, account: first_account, user: user, role: :agent)
        create(:account_user, account: second_account, user: user, role: :administrator)
        sign_in(super_admin, scope: :super_admin)
      end

      it 'offers one audited impersonation button per account without minting a login token' do
        get "/super_admin/users/#{user.id}"
        doc = Nokogiri::HTML(response.body)
        forms = doc.css('form').select { |form| form['action'].to_s.end_with?('/impersonate') }

        expect(response).to have_http_status(:success)
        expect(forms.map { |form| form['action'] }).to contain_exactly(
          "/super_admin/accounts/#{first_account.id}/impersonate",
          "/super_admin/accounts/#{second_account.id}/impersonate"
        )
        expect(forms.map { |form| form.at_css('input[name="user_id"]')['value'] }.uniq).to eq([user.id.to_s])
        expect(forms.map { |form| form['method'] }.uniq).to eq(['post'])
        expect(response.body).not_to include('sso_auth_token')
      end

      it 'words the sign-in block in Russian, without English leftovers or emoji' do
        get "/super_admin/users/#{user.id}"

        expect(response.body).to include('Вход в кабинет аккаунта', 'Войти под пользователем — First Impersonation Account')
        expect(response.body).not_to include('Impersonate')
        expect(response.body).not_to match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/)
      end

      it 'impersonates the opened user through the chosen account' do
        post "/super_admin/accounts/#{second_account.id}/impersonate", params: { user_id: user.id }

        expect(response).to have_http_status(:redirect)
        expect(response.redirect_url).to include('impersonation=true').and include(CGI.escape(user.email))
        audit = Audited::Audit.order(:id).last
        expect(audit).to have_attributes(action: 'impersonate', auditable_id: second_account.id, user_id: super_admin.id)
        expect(audit.audited_changes).to include('impersonated_user_id' => user.id)
      end
    end

    it 'shows the personal API token as its last 4 characters, never the whole token' do
      sign_in(super_admin, scope: :super_admin)
      token = user.access_token.token

      get "/super_admin/users/#{user.id}"

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('#access_token + dd').text.squish).to include("••••#{token.last(4)}")
      expect(response.body).not_to include(token)
      expect(doc.css('[data-secret-text]')).to be_empty
    end

    it 'explains that a user without accounts cannot be impersonated' do
      sign_in(super_admin, scope: :super_admin)

      get "/super_admin/users/#{user.id}"

      expect(response).to have_http_status(:success)
      expect(Nokogiri::HTML(response.body).css('form').map { |form| form['action'].to_s }).not_to include(a_string_ending_with('/impersonate'))
    end
  end

  describe 'the role of a super admin' do
    let!(:plain_user) { create(:user, name: 'Обычный', email: 'plain@example.com') }

    before { sign_in(super_admin, scope: :super_admin) }

    def audits_of(user, action) = Audited::Audit.where(auditable_type: 'User', auditable_id: user.id, action: action).order(:id)

    it 'offers the e-mail confirmation next to the role, in Russian' do
      get "/super_admin/users/#{plain_user.id}/edit"

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('input#user_super_admin_confirmation')).to be_present
      expect(doc.at_css('label[for="user_super_admin_confirmation"]').text.squish).to eq('Подтверждение для супер-администратора')
      expect(doc.text).to include('введите его e-mail')
      expect(doc.css('select#user_type option').map(&:text)).to eq(%w[Пользователь Супер-администратор])
    end

    it 'does not make a user a super admin without the typed e-mail' do
      patch "/super_admin/users/#{plain_user.id}", params: { user: { type: 'SuperAdmin' } }

      expect(response).to redirect_to("/super_admin/users/#{plain_user.id}/edit")
      expect(flash[:alert]).to eq('Чтобы сделать пользователя супер-администратором, введите его e-mail в поле подтверждения. Права не изменены.')
      expect(User.find(plain_user.id)).not_to be_a(SuperAdmin)
    end

    it 'does not make a user a super admin when the typed text is another e-mail' do
      patch "/super_admin/users/#{plain_user.id}", params: { user: { type: 'SuperAdmin', super_admin_confirmation: 'someone@else.com' } }

      expect(response).to redirect_to("/super_admin/users/#{plain_user.id}/edit")
      expect(User.find(plain_user.id)).not_to be_a(SuperAdmin)
    end

    it 'makes the user a super admin when their e-mail is typed, whatever its case, and writes who did it' do
      patch "/super_admin/users/#{plain_user.id}", params: { user: { type: 'SuperAdmin', super_admin_confirmation: '  PLAIN@example.com ' } }

      expect(response).to redirect_to("/super_admin/users/#{plain_user.id}")
      expect(User.find(plain_user.id)).to be_a(SuperAdmin)
      audit = audits_of(plain_user, 'update').last
      expect(audit.audited_changes['type']).to eq([nil, 'SuperAdmin'])
      expect(audit.user_id).to eq(super_admin.id)
    end

    it 'takes the e-mail typed for the new e-mail when the e-mail changes together with the role' do
      patch "/super_admin/users/#{plain_user.id}",
            params: { user: { email: 'new-mail@example.com', type: 'SuperAdmin', super_admin_confirmation: 'new-mail@example.com' } }

      expect(User.find(plain_user.id)).to be_a(SuperAdmin)
    end

    it 'does not create a super admin without the typed e-mail' do
      expect do
        post '/super_admin/users', params: { user: { name: 'Новый', email: 'fresh@example.com', password: 'Password1!', type: 'SuperAdmin' } }
      end.not_to change(User, :count)

      expect(response).to redirect_to('/super_admin/users/new')
      expect(flash[:alert]).to include('введите его e-mail')
    end

    it 'does not accept a role that does not exist' do
      patch "/super_admin/users/#{plain_user.id}", params: { user: { type: 'Administrator' } }

      expect(flash[:alert]).to eq('Такой роли нет. Права пользователя не изменены.')
      expect(User.find(plain_user.id).type).to be_nil
    end

    it 'lets the role stay as it is without a confirmation' do
      patch "/super_admin/users/#{plain_user.id}", params: { user: { type: '', display_name: 'Ещё имя' } }

      expect(response).to redirect_to("/super_admin/users/#{plain_user.id}")
      expect(plain_user.reload.display_name).to eq('Ещё имя')
    end

    it 'does not take the role of a super admin away from himself' do
      patch "/super_admin/users/#{super_admin.id}", params: { user: { type: '' } }

      expect(response).to redirect_to("/super_admin/users/#{super_admin.id}/edit")
      expect(flash[:alert]).to eq('Нельзя снять права супер-администратора с самого себя. Это сделает другой супер-администратор.')
      expect(User.find(super_admin.id)).to be_a(SuperAdmin)
    end

    it 'takes the role away from another super admin while another one is left' do
      other = create(:super_admin, email: 'other-admin@example.com')

      patch "/super_admin/users/#{other.id}", params: { user: { type: '' } }

      expect(response).to redirect_to("/super_admin/users/#{other.id}")
      expect(User.find(other.id)).not_to be_a(SuperAdmin)
    end

    it 'does not take the role away from the last super admin' do
      other = create(:super_admin, email: 'other-admin@example.com')
      allow(SuperAdmin).to receive(:count).and_return(1)

      patch "/super_admin/users/#{other.id}", params: { user: { type: '' } }

      expect(flash[:alert]).to eq('Нельзя убрать права у последнего супер-администратора: на платформе должен остаться хотя бы один.')
      expect(User.find(other.id)).to be_a(SuperAdmin)
    end
  end

  describe 'deleting a user' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'does not delete the super admin who is signed in' do
      expect do
        delete "/super_admin/users/#{super_admin.id}"
      end.not_to change(User, :count)

      expect(response).to redirect_to("/super_admin/users/#{super_admin.id}")
      expect(flash[:alert]).to eq('Нельзя удалить самого себя. Это сделает другой супер-администратор.')
    end

    it 'does not delete the last super admin' do
      other = create(:super_admin, email: 'other-admin@example.com')
      allow(SuperAdmin).to receive(:count).and_return(1)

      expect do
        delete "/super_admin/users/#{other.id}"
      end.not_to change(User, :count)

      expect(flash[:alert]).to eq('Нельзя удалить последнего супер-администратора: на платформе должен остаться хотя бы один.')
    end

    it 'deletes another super admin while one is left, and a plain user, and writes who did it' do
      other = create(:super_admin, email: 'other-admin@example.com')
      plain = create(:user, email: 'to-delete@example.com')

      expect do
        delete "/super_admin/users/#{other.id}"
        delete "/super_admin/users/#{plain.id}"
      end.to change(User, :count).by(-2)

      audit = Audited::Audit.where(auditable_type: 'User', auditable_id: plain.id, action: 'destroy').last
      expect(audit.user_id).to eq(super_admin.id)
      expect(audit.audited_changes).to include('email' => 'to-delete@example.com')
    end
  end

  describe 'the audit log of the changes of a user' do
    let!(:user) { create(:user, name: 'Было', email: 'before@example.com') }

    before { sign_in(super_admin, scope: :super_admin) }

    def update_audits = Audited::Audit.where(auditable_type: 'User', auditable_id: user.id, action: 'update').order(:id)

    it 'records the old and the new name and e-mail, signed by the super admin' do
      patch "/super_admin/users/#{user.id}", params: { user: { name: 'Стало', email: 'after@example.com', confirmed_at: Time.current } }

      audit = update_audits.last
      expect(audit.audited_changes).to include('name' => %w[Было Стало], 'email' => ['before@example.com', 'after@example.com'])
      expect(audit).to have_attributes(user_id: super_admin.id)
    end

    it 'records a new password as changed and never writes it or its hash' do
      old_hash = user.encrypted_password

      patch "/super_admin/users/#{user.id}", params: { user: { password: 'NewSecret123!' } }

      expect(user.reload.encrypted_password).not_to eq(old_hash)
      audit = Audited::Audit.where(auditable_type: 'User', auditable_id: user.id, action: 'change_password').last
      expect(audit).to have_attributes(user_id: super_admin.id, comment: 'super_admin')
      expect(audit.audited_changes).to eq('password' => 'changed')
      all_changes = Audited::Audit.where(auditable_type: 'User', auditable_id: user.id).map { |row| row.audited_changes.to_s }.join
      expect(all_changes).not_to include('NewSecret123!', user.encrypted_password, old_hash)
    end

    it 'writes nothing about the password when it is left empty' do
      patch "/super_admin/users/#{user.id}", params: { user: { name: 'Тот же', password: '' } }

      expect(Audited::Audit.where(auditable_type: 'User', auditable_id: user.id, action: 'change_password')).to be_empty
    end

    it 'does not write the tokens and the second-factor secrets of a user, and not the availability' do
      user.update!(availability: :busy, otp_required_for_login: true, otp_secret: User.generate_otp_secret)

      rows = Audited::Audit.where(auditable_type: 'User', auditable_id: user.id)
      expect(rows.flat_map { |row| row.audited_changes.keys }.uniq - %w[name email display_name type]).to be_empty
    end

    it 'lists the change in the audit log of the super admin by its Russian names' do
      patch "/super_admin/users/#{user.id}", params: { user: { name: 'Стало' } }

      get '/super_admin/audits', params: { auditable_type: 'User', audit_action: 'update' }

      expect(response.body).to include('Пользователь', 'Изменение')
    end
  end
end
