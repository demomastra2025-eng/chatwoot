require 'rails_helper'

RSpec.describe 'Agents API', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let!(:admin) { create(:user, custom_attributes: { test: 'test' }, account: account, role: :administrator) }
  let!(:agent) { create(:user, account: account, email: 'exists@example.com', role: :agent) }

  describe 'GET /api/v1/accounts/{account.id}/agents' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/agents"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let!(:agent) { create(:user, account: account, role: :agent) }

      it 'returns all agents of account' do
        get "/api/v1/accounts/#{account.id}/agents",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(response.parsed_body.size).to eq(account.users.count)
      end

      it 'returns custom fields on agents if present' do
        agent.update(custom_attributes: { test: 'test' })

        get "/api/v1/accounts/#{account.id}/agents",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data.first['custom_attributes']['test']).to eq('test')
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/agents/:id' do
    let(:other_agent) { create(:user, account: account, role: :agent) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns unauthorized for agents' do
        delete "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'deletes the agent and user object if associated with only one account' do
        expect(account.users).to include(other_agent)

        perform_enqueued_jobs(only: DeleteObjectJob) do
          delete "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
                 headers: admin.create_new_auth_token,
                 as: :json
        end

        expect(response).to have_http_status(:success)
        expect(account.reload.users).not_to include(other_agent)
      end

      it 'deletes only the agent object when user is associated with multiple accounts' do
        other_account = create(:account)
        create(:account_user, account_id: other_account.id, user_id: other_agent.id)

        perform_enqueued_jobs(only: DeleteObjectJob) do
          delete "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
                 headers: admin.create_new_auth_token,
                 as: :json
        end

        expect(response).to have_http_status(:success)
        expect(account.reload.users).not_to include(other_agent)
        expect(other_agent.account_users.count).to eq(1) # Should only be associated with other_account now
      end
    end
  end

  describe 'PUT /api/v1/accounts/{account.id}/agents/:id' do
    let(:other_agent) { create(:user, account: account, role: :agent) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      params = { name: 'TestUser' }

      it 'returns unauthorized for agents' do
        put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
            params: params,
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'modifies an agent name' do
        put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
            params: params,
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(other_agent.reload.name).to eq(params[:name])
      end

      it 'modifies an agents account user attributes' do
        put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
            params: { role: 'administrator', availability: 'busy', auto_offline: false },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_data = response.parsed_body
        expect(response_data['role']).to eq('administrator')
        expect(response_data['availability_status']).to eq('busy')
        expect(response_data['auto_offline']).to be(false)
        expect(other_agent.account_users.first.role).to eq('administrator')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/agents' do
    let(:other_agent) { create(:user, account: account, role: :agent) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/agents"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      params = { name: 'NewUser', email: Faker::Internet.email, role: :agent }

      it 'returns unauthorized for agents' do
        post "/api/v1/accounts/#{account.id}/agents",
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'creates a new agent' do
        post "/api/v1/accounts/#{account.id}/agents",
             params: params,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(response.parsed_body['email']).to eq(params[:email])
        expect(account.users.last.name).to eq('NewUser')
      end

      it 'does not consume an agent license for a super admin workspace membership' do
        account.update!(limits: { agents: 3 })
        super_admin = create(:super_admin)
        create(:account_user, account: account, user: super_admin, role: :administrator)

        post "/api/v1/accounts/#{account.id}/agents",
             params: params.merge(email: Faker::Internet.unique.email),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
      end

      it 'allows adding a manually excluded user when the account is already over its agent limit' do
        excluded_user = create(:user)
        account.update!(limits: { agents: 1 }, limit_counter_excluded_user_ids: [excluded_user.id])

        post "/api/v1/accounts/#{account.id}/agents",
             params: params.merge(email: excluded_user.email),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(account.account_users.exists?(user_id: excluded_user.id)).to be(true)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/agents/bulk_create' do
    let(:emails) { ['test1@example.com', 'test2@example.com', 'test3@example.com'] }
    let(:bulk_create_params) { { emails: emails } }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/agents/bulk_create", params: bulk_create_params

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated as admin' do
      it 'creates multiple agents successfully' do
        expect do
          post "/api/v1/accounts/#{account.id}/agents/bulk_create", params: bulk_create_params, headers: admin.create_new_auth_token
        end.to change(User, :count).by(3)

        expect(response).to have_http_status(:ok)
      end

      it 'ignores errors if account_user already exists' do
        params = { emails: ['exists@example.com', 'test1@example.com', 'test2@example.com'] }

        expect do
          post "/api/v1/accounts/#{account.id}/agents/bulk_create", params: params,
                                                                    headers: admin.create_new_auth_token
        end.to change(User, :count).by(2)

        expect(response).to have_http_status(:ok)
      end

      it 'deduplicates new emails when checking the available agent count' do
        account.update!(limits: { agents: 3 })
        duplicated_email = 'duplicate@example.com'

        post "/api/v1/accounts/#{account.id}/agents/bulk_create",
             params: { emails: [duplicated_email, duplicated_email] },
             headers: admin.create_new_auth_token

        expect(response).to have_http_status(:ok)
        expect(account.users.where(email: duplicated_email).count).to eq(1)
      end

      it 'allows an excluded bulk candidate when the account is already over its agent limit' do
        super_admin = create(:super_admin)
        account.update!(limits: { agents: 1 })

        post "/api/v1/accounts/#{account.id}/agents/bulk_create",
             params: { emails: [super_admin.email] },
             headers: admin.create_new_auth_token

        expect(response).to have_http_status(:ok)
        expect(account.account_users.exists?(user_id: super_admin.id)).to be(true)
      end

      it 'normalizes whitespace and treats an existing membership as an idempotent success' do
        post "/api/v1/accounts/#{account.id}/agents/bulk_create",
             params: { emails: ["  #{admin.email.upcase}  "] },
             headers: admin.create_new_auth_token

        expect(response).to have_http_status(:ok)
        expect(account.account_users.where(user_id: admin.id).count).to eq(1)
      end

      it 'reports builder failures and leaves onboarding incomplete' do
        account.update!(custom_attributes: { 'onboarding_step' => 'invite_team' })
        invalid_membership = AccountUser.new
        invalid_membership.errors.add(:base, 'Account user limit exceeded')
        builder = instance_double(AgentBuilder)
        allow(AgentBuilder).to receive(:new).and_return(builder)
        allow(builder).to receive(:perform).and_raise(ActiveRecord::RecordInvalid.new(invalid_membership))

        post "/api/v1/accounts/#{account.id}/agents/bulk_create",
             params: { emails: ['race@example.com'] },
             headers: admin.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['errors']).to be_present
        expect(account.reload.custom_attributes['onboarding_step']).to eq('invite_team')
      end

      it 'retries a concurrent user identity collision once' do
        colliding_builder = instance_double(AgentBuilder, perform: nil)
        successful_builder = instance_double(AgentBuilder, perform: nil)
        allow(colliding_builder).to receive(:perform).and_raise(ActiveRecord::RecordNotUnique)
        allow(AgentBuilder).to receive(:new).and_return(colliding_builder, successful_builder)

        post "/api/v1/accounts/#{account.id}/agents/bulk_create",
             params: { emails: ['race@example.com'] },
             headers: admin.create_new_auth_token

        expect(response).to have_http_status(:ok)
        expect(AgentBuilder).to have_received(:new).twice
      end

      it 'treats a concurrently created membership as an idempotent success' do
        builder = instance_double(AgentBuilder)
        allow(AgentBuilder).to receive(:new).and_return(builder)
        allow(builder).to receive(:perform) do
          user = create(:user, email: 'member-race@example.com')
          create(:account_user, account: account, user: user)
          raise ActiveRecord::RecordInvalid, AccountUser.new
        end

        post "/api/v1/accounts/#{account.id}/agents/bulk_create",
             params: { emails: ['member-race@example.com'] },
             headers: admin.create_new_auth_token

        expect(response).to have_http_status(:ok)
        expect(account.reload.account_users.joins(:user).exists?(users: { email: 'member-race@example.com' })).to be(true)
      end
    end
  end
end
