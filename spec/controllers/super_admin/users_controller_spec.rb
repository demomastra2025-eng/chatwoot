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

    it 'shows the MFA status on the user detail page' do
      sign_in(super_admin, scope: :super_admin)

      get "/super_admin/users/#{user.id}"
      doc = Nokogiri::HTML(response.body)
      labels = doc.css('dt.attribute-label').map { |label| label.text.squish }

      expect(response).to have_http_status(:success)
      expect(labels).to include('MFA')
      expect(response.body).to include('Enabled')
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
