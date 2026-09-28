require 'rails_helper'

RSpec.describe 'Profile API', type: :request do
  let(:account) { create(:account) }

  describe 'GET /api/v1/profile' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get '/api/v1/profile'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, custom_attributes: { test: 'test' }, role: :agent) }

      it 'returns current user information' do
        get '/api/v1/profile',
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        json_response = response.parsed_body
        expect(json_response['id']).to eq(agent.id)
        expect(json_response['email']).to eq(agent.email)
        expect(json_response['access_token']).to eq(agent.access_token.token)
        expect(json_response['custom_attributes']['test']).to eq('test')
        expect(json_response['message_signature']).to be_nil
      end

      it 'keeps legacy permissions in shadow mode without publishing AccessRole mutation grants' do
        AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
        AccessControl::ModeTransition.call(account: account, to: :shadow)

        get '/api/v1/profile', headers: agent.create_new_auth_token, as: :json

        membership = response.parsed_body.fetch('accounts').find { |item| item['id'] == account.id }
        expect(membership).to include('access_control_mode' => 'shadow', 'permissions' => ['agent'])
        expect(membership).not_to have_key('crm_capabilities')
        expect(membership).not_to have_key('crm_grant_scopes')
        expect(membership).not_to have_key('crm_team_ids')
      end

      it 'publishes only active CRM grants in enforced mode for Employee, Observer, Lead and Administrator' do
        account_user = agent.account_users.find_by!(account: account)
        AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
        AccessControl::ModeTransition.call(account: account, to: :shadow)
        AccessControl::ModeTransition.call(account: account, to: :enforced)

        ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'true', ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          %w[employee observer department_lead administrator].each do |key|
            role = account.access_roles.find_by!(system_key: key)
            account_user.reload
            unless account_user.access_role_id == role.id
              AccessControl::AccessRoleAssigner.assign(
                account: account,
                account_user: account_user,
                access_role_id: role.id,
                expected_access_role_id: account_user.access_role_id
              )
            end

            headers = agent.reload.create_new_auth_token
            agent.reload.activate_auth_client!(headers.fetch('client'))
            get '/api/v1/profile', headers: headers, as: :json

            expect(response).to have_http_status(:ok)
            membership = response.parsed_body.fetch('accounts').find { |item| item['id'] == account.id }
            expect(membership).to include(
              'access_control_mode' => 'enforced',
              'permissions' => key == 'administrator' ? ['administrator'] : ['agent']
            )
            capabilities = membership.fetch('crm_capabilities')
            expect(capabilities.values_at('deals', 'tasks').all? { |grants| grants.include?('view') }).to be(true)
            if key == 'observer'
              expect(capabilities.fetch('deals')).not_to include('create', 'update_fields', 'delete_archive')
              expect(capabilities.fetch('tasks')).not_to include('create', 'update_fields', 'complete_cancel')
            else
              expect(capabilities.fetch('deals')).to include('create', 'update_fields', 'assign', 'transition', 'delete_archive')
              expect(capabilities.fetch('tasks')).to include(*%w[create update_fields assign transition complete_cancel delete_archive])
            end
          end
        end
      end

      it 'includes actor team memberships and exact CRM grant scopes in enforced mode' do
        AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
        AccessControl::ModeTransition.call(account: account, to: :shadow)
        AccessControl::ModeTransition.call(account: account, to: :enforced)
        team = create(:team, account: account)
        create(:team_member, team: team, user: agent)

        get '/api/v1/profile', headers: agent.create_new_auth_token, as: :json

        membership = response.parsed_body.fetch('accounts').find { |item| item['id'] == account.id }
        role = agent.account_users.find_by!(account: account).access_role
        scopes = membership.fetch('crm_grant_scopes')
        resources = %w[deals tasks]
        expect(membership.fetch('crm_team_ids')).to eq([team.id])
        resources.each do |resource|
          expected = role.grants.where(resource: resource).index_by(&:capability).transform_values(&:access_scope)
          expect(scopes.fetch(resource)).to eq(expected)
          active_capabilities = expected.filter_map { |capability, scope| capability if scope != 'none' }
          expect(membership.fetch('crm_capabilities').fetch(resource)).to match_array(active_capabilities)
        end
      end

      it 'preloads grants and memberships for multiple enforced accounts without per-account queries' do
        second_account = create(:account)
        create(:account_user, account: second_account, user: agent)
        [account, second_account].each do |member_account|
          AccessControl::LegacyRoleAssigner.call(account: member_account, apply: true)
          AccessControl::ModeTransition.call(account: member_account, to: :shadow)
          AccessControl::ModeTransition.call(account: member_account, to: :enforced)
        end

        statements = []
        subscriber = lambda do |*, payload|
          statements << payload[:sql] if payload[:sql].start_with?('SELECT')
        end
        ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
          get '/api/v1/profile', headers: agent.create_new_auth_token, as: :json
        end

        expect(response.parsed_body.fetch('accounts').pluck('id')).to contain_exactly(account.id, second_account.id)
        expect(statements.grep(/FROM "?account_users"?/).size).to be <= 2
        expect(statements.grep(/FROM "?access_role_grants"?/).size).to be <= 2
      end
    end
  end

  describe 'PUT /api/v1/profile' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        put '/api/v1/profile'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, password: 'Test123!', account: account, role: :agent) }

      it 'updates the name' do
        put '/api/v1/profile',
            params: { profile: { name: 'test' } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        json_response = response.parsed_body
        agent.reload
        expect(json_response['id']).to eq(agent.id)
        expect(json_response['name']).to eq(agent.name)
        expect(agent.name).to eq('test')
      end

      it 'updates custom attributes' do
        put '/api/v1/profile',
            params: { profile: { phone_number: '+123456789' } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        agent.reload

        expect(agent.custom_attributes['phone_number']).to eq('+123456789')
      end

      it 'updates the message_signature' do
        put '/api/v1/profile',
            params: { profile: { name: 'test', message_signature: 'Thanks\nMy Signature' } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        agent.reload
        expect(json_response['id']).to eq(agent.id)
        expect(json_response['name']).to eq(agent.name)
        expect(agent.name).to eq('test')
        expect(json_response['message_signature']).to eq('Thanks\nMy Signature')
      end

      it 'updates the password when current password is provided' do
        put '/api/v1/profile',
            params: { profile: { current_password: 'Test123!', password: 'Test1234!', password_confirmation: 'Test1234!' } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(agent.reload.valid_password?('Test1234!')).to be true
      end

      it 'does not reset the display name if updates the password' do
        display_name = agent.display_name

        put '/api/v1/profile',
            params: { profile: { current_password: 'Test123!', password: 'Test1234!', password_confirmation: 'Test1234!' } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(agent.reload.display_name).to eq(display_name)
      end

      it 'throws error when current password provided is invalid' do
        put '/api/v1/profile',
            params: { profile: { current_password: 'Test', password: 'test123', password_confirmation: 'test123' } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'validate name' do
        user_name = 'test' * 999
        put '/api/v1/profile',
            params: { profile: { name: user_name } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unprocessable_content)
        json_response = response.parsed_body
        expect(json_response['message']).to eq('Name is too long (maximum is 255 characters)')
      end

      it 'updates avatar' do
        # no avatar before upload
        expect(agent.avatar.attached?).to be(false)
        file = fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png')
        put '/api/v1/profile',
            params: { profile: { avatar: file } },
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:success)
        agent.reload
        expect(agent.avatar.attached?).to be(true)
      end

      it 'updates the ui settings' do
        put '/api/v1/profile',
            params: { profile: { ui_settings: { is_contact_sidebar_open: false } } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['ui_settings']['is_contact_sidebar_open']).to be(false)
      end

      it 'persists the incoming call ringtone in ui settings' do
        ringtone = 'universfield-ringtone-091-496417.mp3'

        put '/api/v1/profile',
            params: { profile: { ui_settings: { incoming_call_ringtone: ringtone } } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('ui_settings', 'incoming_call_ringtone')).to eq(ringtone)
        expect(agent.reload.ui_settings['incoming_call_ringtone']).to eq(ringtone)
      end

      it 'updates sidebar visibility preferences in ui settings' do
        put '/api/v1/profile',
            params: {
              profile: {
                ui_settings: {
                  dashboard_sidebar_hidden_items: %w[Reports Settings]
                }
              }
            },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['ui_settings']['dashboard_sidebar_hidden_items']).to eq(%w[Reports Settings])
      end
    end

    context 'when an authenticated user updates email' do
      let(:agent) { create(:user, password: 'Test123!', account: account, role: :agent) }

      it 'populates the unconfirmed email' do
        new_email = Faker::Internet.email
        put '/api/v1/profile',
            params: { profile: { email: new_email } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        agent.reload

        expect(agent.unconfirmed_email).to eq(new_email)
      end
    end
  end

  describe 'DELETE /api/v1/profile/avatar' do
    let(:agent) { create(:user, password: 'Test123!', account: account, role: :agent) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete '/api/v1/profile/avatar'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      before do
        agent.avatar.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
      end

      it 'deletes the agent avatar' do
        delete '/api/v1/profile/avatar',
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['avatar_url']).to be_empty
      end
    end
  end

  describe 'POST /api/v1/profile/availability' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post '/api/v1/profile/availability'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, password: 'Test123!', account: account, role: :agent) }

      it 'updates the availability status' do
        post '/api/v1/profile/availability',
             params: { profile: { availability: 'busy', account_id: account.id } },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['accounts'].first['availability']).to eq('busy')
        expect(OnlineStatusTracker.get_status(account.id, agent.id)).to eq('busy')
      end
    end
  end

  describe 'POST /api/v1/profile/auto_offline' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post '/api/v1/profile/auto_offline'
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, password: 'Test123!', account: account, role: :agent) }

      it 'updates the auto offline status' do
        post '/api/v1/profile/auto_offline',
             params: { profile: { auto_offline: false, account_id: account.id } },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['accounts'].first['auto_offline']).to be(false)
      end
    end
  end

  describe 'PUT /api/v1/profile/set_active_account' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        put '/api/v1/profile/set_active_account'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, password: 'Test123!', account: account, role: :agent) }

      it 'updates the last active account id' do
        put '/api/v1/profile/set_active_account',
            params: { profile: { account_id: account.id } },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
      end
    end
  end

  describe 'POST /api/v1/profile/resend_confirmation' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post '/api/v1/profile/resend_confirmation'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) do
        create(:user, password: 'Test123!', email: 'test-unconfirmed@email.com', account: account, role: :agent,
                      unconfirmed_email: 'test-unconfirmed@email.com')
      end

      it 'does not send the confirmation email if the user is already confirmed' do
        expect do
          post '/api/v1/profile/resend_confirmation',
               headers: agent.create_new_auth_token,
               as: :json
        end.not_to have_enqueued_mail(Devise::Mailer, :confirmation_instructions)

        expect(response).to have_http_status(:success)
      end

      it 'resends the confirmation email if the user is unconfirmed' do
        agent.confirmed_at = nil
        agent.save!

        expect do
          post '/api/v1/profile/resend_confirmation',
               headers: agent.create_new_auth_token,
               as: :json
        end.to have_enqueued_mail(Devise::Mailer, :confirmation_instructions)

        expect(response).to have_http_status(:success)
      end
    end
  end

  describe 'POST /api/v1/profile/reset_access_token' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post '/api/v1/profile/reset_access_token'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      it 'regenerates the access token' do
        old_token = agent.access_token.token

        post '/api/v1/profile/reset_access_token',
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        agent.reload
        expect(agent.access_token.token).not_to eq(old_token)
        json_response = response.parsed_body
        expect(json_response['access_token']).to eq(agent.access_token.token)
      end
    end
  end
end
