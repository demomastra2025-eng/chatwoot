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
          type: 'SuperAdmin'
        } }
      end
      let!(:params_without_confirmed_at) do
        { user: {
          name: 'agent@example.com',
          display_name: 'agent@example.com',
          email: 'agent@example.com',
          password: 'Password1!',
          type: 'SuperAdmin'
        } }
      end
      let!(:params_with_blank_confirmed_at) do
        { user: {
          name: 'agent-2@example.com',
          display_name: 'agent-2@example.com',
          email: 'agent-2@example.com',
          password: 'Password1!',
          confirmed_at: '',
          type: 'SuperAdmin'
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

    it 'explains that a user without accounts cannot be impersonated' do
      sign_in(super_admin, scope: :super_admin)

      get "/super_admin/users/#{user.id}"

      expect(response).to have_http_status(:success)
      expect(Nokogiri::HTML(response.body).css('form').map { |form| form['action'].to_s }).not_to include(a_string_ending_with('/impersonate'))
    end
  end
end
