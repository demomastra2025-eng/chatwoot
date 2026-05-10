require 'rails_helper'

RSpec.describe 'Notification Settings API', type: :request do
  let(:account) { create(:account) }

  describe 'GET /api/v1/accounts/{account.id}/notification_settings' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/notification_settings"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      it 'returns current user notification settings' do
        get "/api/v1/accounts/#{account.id}/notification_settings",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['user_id']).to eq(agent.id)
        expect(json_response['account_id']).to eq(account.id)
        expect(json_response['selected_inbox_flags'])
          .to match_array(NotificationSetting.default_inbox_flag_names.map(&:to_s))
        expect(json_response['selected_telegram_flags']).to eq([])
        expect(json_response['telegram_connection']).to include('connected' => false)
      end
    end
  end

  describe 'PUT /api/v1/accounts/{account.id}/notification_settings' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        put "/api/v1/accounts/#{account.id}/notification_settings"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      it 'updates the email related notification flags' do
        put "/api/v1/accounts/#{account.id}/notification_settings",
            params: {
              notification_settings: {
                selected_email_flags: ['email_conversation_assignment'],
                selected_inbox_flags: ['inbox_conversation_assignment'],
                selected_telegram_flags: ['telegram_conversation_assignment']
              }
            },
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        agent.reload
        expect(json_response['user_id']).to eq(agent.id)
        expect(json_response['account_id']).to eq(account.id)
        expect(json_response['selected_email_flags']).to eq(['email_conversation_assignment'])
        expect(json_response['selected_inbox_flags']).to eq(['inbox_conversation_assignment'])
        expect(json_response['selected_telegram_flags']).to eq(['telegram_conversation_assignment'])
      end

      it 'disconnects telegram and clears telegram notification flags' do
        binding = create(:telegram_notification_binding, :connected, user: agent)
        setting = agent.notification_settings.find_by(account_id: account.id)
        setting.selected_telegram_flags = [:telegram_conversation_assignment]
        setting.save!

        delete "/api/v1/accounts/#{account.id}/notification_settings/disconnect_telegram",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(binding.reload).not_to be_connected
        expect(response.parsed_body['selected_telegram_flags']).to eq([])
      end
    end
  end
end
