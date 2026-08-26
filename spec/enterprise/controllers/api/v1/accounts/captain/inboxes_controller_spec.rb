require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Inboxes', type: :request do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:inbox2) { create(:inbox, account: account) }
  let!(:captain_inbox) { create(:captain_inbox, captain_assistant: assistant, inbox: inbox) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/:account_id/captain/assistants/:assistant_id/inboxes' do
    context 'when user is authorized' do
      it 'returns a list of inboxes for the assistant' do
        get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:ok)
        expect(json_response[:payload].first[:id]).to eq(captain_inbox.inbox.id)
      end
    end

    context 'when user is unauthorized' do
      it 'returns unauthorized status' do
        get "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when assistant does not exist' do
      it 'returns not found status' do
        get "/api/v1/accounts/#{account.id}/captain/assistants/999999/inboxes",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST /api/v1/accounts/:account/captain/assistants/:assistant_id/inboxes' do
    let(:valid_params) do
      {
        inbox: {
          inbox_id: inbox2.id
        }
      }
    end

    context 'when user is authorized' do
      it 'creates a new captain inbox' do
        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
               params: valid_params,
               headers: admin.create_new_auth_token
        end.to change(CaptainInbox, :count).by(1)

        expect(response).to have_http_status(:success)
        expect(json_response[:id]).to eq(inbox2.id)
        expect(json_response[:captain_auto_reply_mode]).to eq('always')
        expect(json_response[:captain_reply_to_open_conversations]).to be(false)
      end

      it 'creates a captain inbox with the requested auto-reply mode' do
        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
             params: { inbox: { inbox_id: inbox2.id, auto_reply_mode: 'outside_working_hours' } },
             headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(CaptainInbox.find_by!(inbox: inbox2)).to have_attributes(auto_reply_mode: 'outside_working_hours')
        expect(json_response[:captain_auto_reply_mode]).to eq('outside_working_hours')
      end

      it 'updates the auto-reply mode when the same assistant is already connected to the inbox' do
        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
             params: { inbox: { inbox_id: inbox.id, auto_reply_mode: 'working_hours' } },
             headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(captain_inbox.reload.auto_reply_mode).to eq('working_hours')
        expect(json_response[:captain_auto_reply_mode]).to eq('working_hours')
      end

      it 'updates reply-to-open-conversations when the same assistant is already connected to the inbox' do
        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
             params: { inbox: { inbox_id: inbox.id, reply_to_open_conversations: true } },
             headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(captain_inbox.reload.reply_to_open_conversations).to be(true)
        expect(json_response[:captain_reply_to_open_conversations]).to be(true)
      end

      it 'rejects removed never auto-reply mode' do
        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
               params: { inbox: { inbox_id: inbox2.id, auto_reply_mode: 'never' } },
               headers: admin.create_new_auth_token
        end.not_to change(CaptainInbox, :count)

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects an invalid auto-reply mode' do
        expect do
          post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
               params: { inbox: { inbox_id: inbox2.id, auto_reply_mode: 'weekends_only' } },
               headers: admin.create_new_auth_token
        end.not_to change(CaptainInbox, :count)

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'enables the AI side of a voice routing policy when Captain connects to a voice inbox' do
        account.enable_features!('channel_voice')
        voice_channel = create(
          :channel_voice,
          :sipuni,
          account: account,
          provider_config: {
            number_ref: SecureRandom.uuid,
            app_ref: 'runtime-app-ref',
            app_route_app_ref: 'fallback-app-ref',
            trunk_ref: SecureRandom.uuid,
            routing_mode: 'operator',
            operator_agent_aor: 'sip:1001@example.test'
          }
        )
        voice_inbox = voice_channel.inbox
        policy = voice_inbox.telephony_number_binding.routing_policy
        policy.update!(mode: 'operator', operator_agent_aor: 'sip:1001@example.test', fallback_mode: 'reject', ai_enabled: false)

        with_modified_env(ONELINK_AI_VOICE_APP_REF: 'onelink-managed-ai-app-ref') do
          post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
               params: { inbox: { inbox_id: voice_inbox.id } },
               headers: admin.create_new_auth_token
        end

        expect(response).to have_http_status(:success)
        expect(policy.reload).to have_attributes(
          mode: 'operator',
          ai_enabled: true,
          ai_deployment_mode: 'onelink_managed',
          onelink_ai_app_ref: 'onelink-managed-ai-app-ref',
          fallback_mode: 'app',
          captain_assistant_id: assistant.id
        )
      end

      it 'backfills existing voice routing policies for previously connected Captain inboxes' do
        account.enable_features!('channel_voice')
        voice_channel = create(
          :channel_voice,
          :sipuni,
          account: account,
          provider_config: {
            number_ref: SecureRandom.uuid,
            app_ref: 'runtime-app-ref',
            app_route_app_ref: 'fallback-app-ref',
            trunk_ref: SecureRandom.uuid,
            routing_mode: 'operator',
            operator_agent_aor: 'sip:1001@example.test'
          }
        )
        voice_inbox = voice_channel.inbox
        existing_link = create(:captain_inbox, captain_assistant: assistant, inbox: voice_inbox)
        policy = voice_inbox.telephony_number_binding.routing_policy
        policy.update!(
          mode: 'operator',
          operator_agent_aor: 'sip:1001@example.test',
          fallback_mode: 'reject',
          ai_enabled: false,
          ai_deployment_mode: 'onelink_managed',
          onelink_ai_app_ref: nil,
          captain_assistant_id: nil
        )

        with_modified_env(ONELINK_AI_VOICE_APP_REF: 'onelink-managed-ai-app-ref') do
          CaptainInbox.sync_voice_routing_policies!
        end

        expect(existing_link.reload).to be_present
        expect(policy.reload).to have_attributes(
          mode: 'operator',
          ai_enabled: true,
          ai_deployment_mode: 'onelink_managed',
          onelink_ai_app_ref: 'onelink-managed-ai-app-ref',
          fallback_mode: 'app',
          captain_assistant_id: assistant.id
        )
      end

      context 'when inbox does not exist' do
        it 'returns not found status' do
          post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
               params: { inbox: { inbox_id: 999_999 } },
               headers: admin.create_new_auth_token

          expect(response).to have_http_status(:not_found)
        end
      end

      context 'when params are invalid' do
        it 'returns unprocessable entity status' do
          post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
               params: {},
               headers: admin.create_new_auth_token

          expect(response).to have_http_status(:unprocessable_content)
        end
      end
    end

    context 'when user is agent' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes",
             params: valid_params,
             headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/captain/assistants/:assistant_id/inboxes/:inbox_id' do
    context 'when user is authorized' do
      it 'deletes the captain inbox' do
        expect do
          delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes/#{inbox.id}",
                 headers: admin.create_new_auth_token
        end.to change(CaptainInbox, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end

      context 'when captain inbox does not exist' do
        it 'returns not found status' do
          delete "/api/v1/accounts/#{account.id}/captain/assistants/#{assistant.id}/inboxes/999999",
                 headers: admin.create_new_auth_token

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end
end
