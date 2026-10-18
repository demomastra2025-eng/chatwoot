require 'rails_helper'

RSpec.describe 'Platform Users API', type: :request do
  let!(:user) { create(:user, email: 'dev+testing@one-link.kz', custom_attributes: { test: 'test' }) }

  describe 'GET /platform/api/v1/users/{user_id}' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        get "/platform/api/v1/users/#{user.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        get "/platform/api/v1/users/#{user.id}", headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'returns unauthorized when its not a permissible object' do
        get "/platform/api/v1/users/#{user.id}", headers: { api_access_token: platform_app.access_token.token }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'shows a user when its permissible object' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: user)

        get "/platform/api/v1/users/#{user.id}",
            headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data['email']).to eq(user.email)
        expect(data['custom_attributes']['test']).to eq('test')
      end
    end
  end

  describe 'GET /platform/api/v1/users/{user_id}/login' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        get "/platform/api/v1/users/#{user.id}/login"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        get "/platform/api/v1/users/#{user.id}/login", headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'returns unauthorized when its not a permissible object' do
        get "/platform/api/v1/users/#{user.id}/login", headers: { api_access_token: platform_app.access_token.token }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'return login link for user' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: user)

        get "/platform/api/v1/users/#{user.id}/login",
            headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data['url']).to include('email=dev%2Btesting%40one-link.kz&sso_auth_token=')
      end
    end
  end

  describe 'POST /platform/api/v1/users/{user_id}/token' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        post "/platform/api/v1/users/#{user.id}/token"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        post "/platform/api/v1/users/#{user.id}/token", headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'returns unauthorized when its not a permissible object' do
        post "/platform/api/v1/users/#{user.id}/token", headers: { api_access_token: platform_app.access_token.token }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns access token for the user with expiry and user info' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: user)

        post "/platform/api/v1/users/#{user.id}/token",
             headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body

        # Check access token and expiry
        expect(data['access_token']).to eq(user.access_token.token)
        expect(data['expiry']).to be_nil

        # Check user info
        expect(data['user']).to include(
          'id' => user.id,
          'name' => user.name,
          'display_name' => user.display_name,
          'email' => user.email,
          'pubsub_token' => user.pubsub_token
        )
      end
    end
  end

  describe 'POST /platform/api/v1/users/' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        post '/platform/api/v1/users'
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        post '/platform/api/v1/users/', headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'creates a new user and permissible for the user without sending an email' do
        # TODO: enqueued mail check failes because of  : https://github.com/rspec/rspec-rails/pull/2793
        # revert to this block when the issue is fixed

        # expect do
        #   post '/platform/api/v1/users/', params: { name: 'test', display_name: 'displaytest',
        #                                             email: 'test@test.com', password: 'Password1!',
        #                                             custom_attributes: { test: 'test_create' } },
        #                                   headers: { api_access_token: platform_app.access_token.token }, as: :json
        #   byebug
        # end.not_to have_enqueued_mail

        ##------ revert this block when the issue is fixed
        post '/platform/api/v1/users/', params: { name: 'test', display_name: 'displaytest',
                                                  email: 'test@test.com', password: 'Password1!',
                                                  custom_attributes: { test: 'test_create' } },
                                        headers: { api_access_token: platform_app.access_token.token }, as: :json
        mail_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select do |job|
          job[:job] == 'ActionMailer::MailDeliveryJob'
        end
        expect(mail_jobs.count).to eq(0)
        ##------ revert this block when the issue is fixed

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data).to match(
          hash_including(
            'name' => 'test',
            'display_name' => 'displaytest',
            'email' => 'test@test.com',
            'custom_attributes' => {
              'test' => 'test_create'
            }
          )
        )
        expect(platform_app.platform_app_permissibles.first.permissible_id).to eq data['id']
      end

      it 'refuses an e-mail of a user it did not create and attaches nothing' do
        existing = create(:user, name: 'old test', email: 'test@test.com')

        expect do
          post '/platform/api/v1/users/', params: { name: 'test', email: 'test@test.com', password: 'Password1!' },
                                          headers: { api_access_token: platform_app.access_token.token }, as: :json
        end.not_to change(PlatformAppPermissible, :count)

        expect(response).to have_http_status(:conflict)
        expect(response.parsed_body).to include('code' => 'email_taken')
        expect(response.body).not_to include('old test')
        expect(existing.reload.name).to eq('old test')
      end

      it 'refuses the e-mail of a super admin in the same words and never hands out its token' do
        super_admin = create(:super_admin, email: 'root@one-link.kz')
        headers = { api_access_token: platform_app.access_token.token }

        post '/platform/api/v1/users/', params: { name: 'x', email: 'root@one-link.kz', password: 'Password1!' }, headers: headers, as: :json
        super_admin_answer = response.parsed_body
        expect(response).to have_http_status(:conflict)
        expect(response.body).not_to include(super_admin.access_token.token)

        create(:user, email: 'plain@one-link.kz')
        post '/platform/api/v1/users/', params: { name: 'x', email: 'plain@one-link.kz', password: 'Password1!' }, headers: headers, as: :json
        expect(response.parsed_body).to eq(super_admin_answer)
        expect(platform_app.platform_app_permissibles).to be_empty
      end

      it 'matches the e-mail without regard to case' do
        create(:user, email: 'mixed@one-link.kz')

        post '/platform/api/v1/users/', params: { name: 'x', email: 'MIXED@one-link.kz', password: 'Password1!' },
                                        headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:conflict)
      end

      it 'returns its own user again when the same e-mail is sent twice, without changing it or writing a second entry' do
        headers = { api_access_token: platform_app.access_token.token }
        post '/platform/api/v1/users/', params: { name: 'first', email: 'again@one-link.kz', password: 'Password1!' }, headers: headers, as: :json
        first_id = response.parsed_body['id']

        expect do
          post '/platform/api/v1/users/', params: { name: 'second', email: 'again@one-link.kz', password: 'Other1234!' }, headers: headers, as: :json
        end.not_to change(Audited::Audit, :count)

        expect(response).to have_http_status(:success)
        expect(response.parsed_body).to include('id' => first_id, 'name' => 'first')
        expect(platform_app.platform_app_permissibles.count).to eq(1)
      end

      it 'does not return an own user that is a super admin (an old attachment)' do
        old_attachment = create(:super_admin, email: 'old@one-link.kz', name: 'Root')
        create(:platform_app_permissible, platform_app: platform_app, permissible: old_attachment)

        post '/platform/api/v1/users/', params: { name: 'x', email: 'old@one-link.kz', password: 'Password1!' },
                                        headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:conflict)
      end

      it 'does not take a super admin type from the request' do
        post '/platform/api/v1/users/', params: { name: 'test', email: 'tries@one-link.kz', password: 'Password1!', type: 'SuperAdmin' },
                                        headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(User.from_email('tries@one-link.kz')).not_to be_a(SuperAdmin)
      end

      it 'writes an entry of the audit log with the partner as the actor and no password in it' do
        post '/platform/api/v1/users/', params: { name: 'test', display_name: 'displaytest', email: 'audit@one-link.kz', password: 'Password1!' },
                                        headers: { api_access_token: platform_app.access_token.token }, as: :json

        created = User.find_by!(email: 'audit@one-link.kz')
        audit = Audited::Audit.where(auditable: created, action: 'partner_create_user').last
        expect(audit).to have_attributes(user_id: platform_app.id, user_type: 'PlatformApp', comment: 'platform_app')
        expect(audit.audited_changes).to eq('name' => 'test', 'display_name' => 'displaytest', 'email' => 'audit@one-link.kz')
        expect(audit.audited_changes.to_s).not_to include('Password1!')
      end

      it 'creates nothing and records nothing when the data is not valid' do
        expect do
          post '/platform/api/v1/users/', params: { name: 'test', email: '', password: 'Password1!' },
                                          headers: { api_access_token: platform_app.access_token.token }, as: :json
        end.not_to change(User, :count)

        expect(response).to have_http_status(:unprocessable_content)
        expect(Audited::Audit.where(action: 'partner_create_user')).to be_empty
      end
    end
  end

  describe 'a super admin through the Platform API' do
    let(:platform_app) { create(:platform_app) }
    let(:headers) { { api_access_token: platform_app.access_token.token } }
    let!(:super_admin) { create(:super_admin, name: 'Root', email: 'root@one-link.kz') }

    before { create(:platform_app_permissible, platform_app: platform_app, permissible: super_admin) }

    it 'can be neither read nor signed in as nor given a token for, even with an old attachment' do
      get "/platform/api/v1/users/#{super_admin.id}", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)

      get "/platform/api/v1/users/#{super_admin.id}/login", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include('sso_auth_token')

      post "/platform/api/v1/users/#{super_admin.id}/token", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(super_admin.access_token.token)
    end

    it 'can be neither changed nor deleted, even with an old attachment' do
      patch "/platform/api/v1/users/#{super_admin.id}", params: { email: 'taken@over.kz', password: 'Hacked123!' }, headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(super_admin.reload.email).to eq('root@one-link.kz')

      expect(DeleteObjectJob).not_to receive(:perform_later)
      delete "/platform/api/v1/users/#{super_admin.id}", headers: headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'writes nothing to the audit log for the refused calls' do
      patch "/platform/api/v1/users/#{super_admin.id}", params: { name: 'Hacked' }, headers: headers, as: :json

      expect(Audited::Audit.where(user_type: 'PlatformApp')).to be_empty
    end
  end

  describe 'the audit log of the other calls of a partner on its own user' do
    let(:platform_app) { create(:platform_app) }
    let(:headers) { { api_access_token: platform_app.access_token.token } }

    before { create(:platform_app_permissible, platform_app: platform_app, permissible: user) }

    def last_audit(action) = Audited::Audit.where(auditable: user, action: action).last

    it 'records the sign-in link that was issued, without the link' do
      get "/platform/api/v1/users/#{user.id}/login", headers: headers, as: :json

      audit = last_audit('partner_login_link')
      expect(audit).to have_attributes(user_id: platform_app.id, user_type: 'PlatformApp')
      expect(audit.audited_changes.to_s).not_to include('sso_auth_token')
    end

    it 'records that the token of the user was handed out, without the token' do
      post "/platform/api/v1/users/#{user.id}/token", headers: headers, as: :json

      audit = last_audit('partner_user_token')
      expect(audit).to have_attributes(user_id: platform_app.id)
      expect(audit.audited_changes.to_s).not_to include(user.access_token.token)
    end

    it 'records a change with the old and the new value, and only the word changed for a password' do
      old_name = user.name

      patch "/platform/api/v1/users/#{user.id}",
            params: { name: 'Renamed', email: 'renamed@one-link.kz', password: 'NewPass123!', custom_attributes: { plan: 'x' } },
            headers: headers, as: :json

      expect(response).to have_http_status(:success)
      audit = last_audit('partner_update_user')
      expect(audit.audited_changes).to include(
        'name' => [old_name, 'Renamed'],
        'email' => ['dev+testing@one-link.kz', 'renamed@one-link.kz'],
        'password' => 'changed', 'custom_attributes' => 'changed'
      )
      expect(audit.audited_changes.to_s).not_to include('NewPass123!')
    end

    it 'records nothing for an update that changes nothing' do
      expect do
        patch "/platform/api/v1/users/#{user.id}", params: { name: user.name }, headers: headers, as: :json
      end.not_to change(Audited::Audit, :count)
    end

    it 'records the deletion with the e-mail and the name of the user' do
      allow(DeleteObjectJob).to receive(:perform_later)

      delete "/platform/api/v1/users/#{user.id}", headers: headers, as: :json

      expect(last_audit('partner_destroy_user').audited_changes).to include('email' => 'dev+testing@one-link.kz', 'name' => user.name)
    end

    it 'does not touch a user of another partner' do
      other = create(:platform_app)
      patch "/platform/api/v1/users/#{user.id}", params: { name: 'Hijack' }, headers: { api_access_token: other.access_token.token }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(user.reload.name).not_to eq('Hijack')
    end
  end

  describe 'PATCH /platform/api/v1/users/{user_id}' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        patch "/platform/api/v1/users/#{user.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        patch "/platform/api/v1/users/#{user.id}", headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'returns unauthorized when its not a permissible object' do
        patch "/platform/api/v1/users/#{user.id}", params: { name: 'test' },
                                                   headers: { api_access_token: platform_app.access_token.token }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'updates the user attributes' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: user)
        patch "/platform/api/v1/users/#{user.id}", params: {
                                                     name: 'test123', email: 'newtestemail@test.com', custom_attributes: { test: 'test_update' }
                                                   },
                                                   headers: { api_access_token: platform_app.access_token.token }, as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data['name']).to eq('test123')
        expect(data['email']).to eq('newtestemail@test.com')
        expect(data['custom_attributes']['test']).to eq('test_update')
      end
    end
  end

  describe 'DELETE /platform/api/v1/users/{user_id}' do
    context 'when it is an unauthenticated platform app' do
      it 'returns unauthorized' do
        delete "/platform/api/v1/users/#{user.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an invalid platform app token' do
      it 'returns unauthorized' do
        delete "/platform/api/v1/users/#{user.id}", headers: { api_access_token: 'invalid' }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated platform app' do
      let(:platform_app) { create(:platform_app) }

      it 'returns unauthorized when its not a permissible object' do
        delete "/platform/api/v1/users/#{user.id}", headers: { api_access_token: platform_app.access_token.token }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'deletes the user' do
        create(:platform_app_permissible, platform_app: platform_app, permissible: user)
        expect(DeleteObjectJob).to receive(:perform_later).with(user).once
        delete "/platform/api/v1/users/#{user.id}",
               headers: { api_access_token: platform_app.access_token.token }, as: :json
        expect(response).to have_http_status(:success)
      end
    end
  end
end
