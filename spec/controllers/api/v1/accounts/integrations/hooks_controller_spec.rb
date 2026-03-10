require 'rails_helper'

RSpec.describe 'Integration Hooks API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:params) { { app_id: 'dialogflow', inbox_id: inbox.id, settings: { project_id: 'xx', credentials: { test: 'test' }, region: 'europe-west1' } } }
  let(:macrocrm_params) do
    {
      app_id: 'macrocrm',
      access_token: 'macro-secret',
      status: 'enabled',
      settings: {
        app_id: 'macro-app',
        sync_incoming_messages: true,
        sync_outgoing_messages: false
      }
    }
  end

  describe 'POST /api/v1/accounts/{account.id}/integrations/hooks' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: params,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'return unauthorized if agent' do
        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'creates hooks if admin' do
        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: params,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data['app_id']).to eq params[:app_id]
      end

      it 'creates a macrocrm hook with an encrypted access token' do
        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: macrocrm_params,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        hook = Integrations::Hook.last

        expect(hook.app_id).to eq 'macrocrm'
        expect(hook.access_token).to eq 'macro-secret'
        expect(hook.settings['app_id']).to eq 'macro-app'
        expect(response.parsed_body).not_to have_key('access_token')
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/integrations/hooks/{hook_id}' do
    let(:hook) { create(:integrations_hook, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        patch api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
              params: params,
              as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'return unauthorized if agent' do
        patch api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
              params: params,
              headers: agent.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'updates hook if admin' do
        patch api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
              params: params,
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data['app_id']).to eq 'slack'
      end

      it 'updates macrocrm settings without clearing an existing token when a blank token is submitted' do
        hook = create(:integrations_hook,
                      account: account,
                      app_id: 'macrocrm',
                      access_token: 'existing-secret',
                      settings: {
                        'app_id' => 'macro-app',
                        'sync_incoming_messages' => true,
                        'sync_outgoing_messages' => true
                      })

        patch api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
              params: {
                status: false,
                access_token: '',
                settings: {
                  app_id: 'macro-app-updated',
                  sync_incoming_messages: false,
                  sync_outgoing_messages: true
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(hook.reload.access_token).to eq 'existing-secret'
        expect(hook.disabled?).to be true
        expect(hook.settings['app_id']).to eq 'macro-app-updated'
        expect(hook.settings['sync_incoming_messages']).to be false
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/integrations/hooks/{hook_id}/process_event' do
    let(:hook) { create(:integrations_hook, account: account) }
    let(:params) { { event: 'rephrase', payload: { test: 'test' } } }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post process_event_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
             params: params,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'will process the events' do
        post process_event_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq 'No processor found'
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/integrations/hooks/{hook_id}' do
    let(:hook) { create(:integrations_hook, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'return unauthorized if agent' do
        delete api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'updates hook if admin' do
        delete api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
               headers: admin.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(Integrations::Hook.exists?(hook.id)).to be false
      end
    end
  end
end
