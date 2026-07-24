require 'rails_helper'

RSpec.describe 'Inboxes API', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  describe 'GET /api/v1/accounts/{account.id}/inboxes' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/inboxes"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:inbox) { create(:inbox, account: account) }

      before do
        create(:inbox, account: account)
        create(:inbox_member, user: agent, inbox: inbox)
      end

      it 'returns all inboxes of current_account as administrator' do
        get "/api/v1/accounts/#{account.id}/inboxes",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(JSON.parse(response.body, symbolize_names: true)[:payload].size).to eq(2)
      end

      it 'includes campaign capabilities in the inbox payload' do
        email_inbox = create(:channel_email, account: account).inbox

        get "/api/v1/accounts/#{account.id}/inboxes",
            headers: admin.create_new_auth_token,
            as: :json

        payload = JSON.parse(response.body, symbolize_names: true)[:payload]
        email_payload = payload.find { |item| item[:id] == email_inbox.id }

        expect(email_payload).to be_present
        expect(email_payload[:campaign_capabilities]).to include(
          supports_outbound_campaigns: true,
          implemented_in_current_campaigns: true,
          delivery_readiness: 'ready',
          supports_subject: true,
          supports_html: true
        )
      end

      it 'returns only assigned inboxes of current_account as agent' do
        get "/api/v1/accounts/#{account.id}/inboxes",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:payload].size).to eq(1)
      end

      context 'when provider_config' do
        let(:inbox) { create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox }

        it 'returns provider config attributes for admin' do
          get "/api/v1/accounts/#{account.id}/inboxes",
              headers: admin.create_new_auth_token,
              as: :json
          expect(response.body).to include('provider_config')
        end

        it 'will not return provider config for agent' do
          get "/api/v1/accounts/#{account.id}/inboxes",
              headers: agent.create_new_auth_token,
              as: :json

          expect(response.body).not_to include('provider_config')
        end
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/inboxes/{inbox.id}' do
    let(:inbox) { create(:inbox, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:inbox) { create(:inbox, account: account) }

      it 'returns unauthorized for an agent who is not assigned' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns the inbox if administrator' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(JSON.parse(response.body, symbolize_names: true)[:id]).to eq(inbox.id)
      end

      it 'returns the inbox if assigned inbox is assigned as agent' do
        create(:inbox_member, user: agent, inbox: inbox)
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        data = JSON.parse(response.body, symbolize_names: true)
        expect(data[:id]).to eq(inbox.id)
        expect(data[:hmac_token]).to be_nil
      end

      it 'does not expose legacy Sipuni webhook details for voice inboxes' do
        voice_channel = create(:channel_voice, :sipuni, account: account)
        voice_inbox = voice_channel.inbox
        create(:inbox_member, user: agent, inbox: voice_inbox)

        get "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        data = JSON.parse(response.body, symbolize_names: true)
        expect(data).not_to have_key(:sipuni_events_webhook_url)
      end

      it 'returns empty imap details in inbox when agent' do
        email_channel = create(:channel_email, account: account, imap_enabled: true, imap_login: 'test@test.com')
        email_inbox = create(:inbox, channel: email_channel, account: account)
        create(:inbox_member, user: agent, inbox: email_inbox)

        imap_connection = double
        allow(Mail).to receive(:connection).and_return(imap_connection)

        get "/api/v1/accounts/#{account.id}/inboxes/#{email_inbox.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        data = JSON.parse(response.body, symbolize_names: true)

        expect(data[:imap_enabled]).to be_nil
        expect(data[:imap_login]).to be_nil
      end

      it 'returns imap details in inbox when admin' do
        email_channel = create(:channel_email, account: account, imap_enabled: true, imap_login: 'test@test.com', imap_authentication: 'login')
        email_inbox = create(:inbox, channel: email_channel, account: account)

        imap_connection = double
        allow(Mail).to receive(:connection).and_return(imap_connection)

        get "/api/v1/accounts/#{account.id}/inboxes/#{email_inbox.id}",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        data = JSON.parse(response.body, symbolize_names: true)

        expect(data[:imap_enabled]).to be_truthy
        expect(data[:imap_login]).to eq('test@test.com')
        expect(data[:imap_authentication]).to eq('login')
      end

      context 'when it is a Twilio inbox' do
        let(:twilio_channel) { create(:channel_twilio_sms, account: account, account_sid: 'AC123', auth_token: 'secrettoken') }
        let(:twilio_inbox) { create(:inbox, channel: twilio_channel, account: account) }

        it 'returns auth_token and account_sid for admin' do
          get "/api/v1/accounts/#{account.id}/inboxes/#{twilio_inbox.id}",
              headers: admin.create_new_auth_token,
              as: :json
          expect(response).to have_http_status(:success)
          data = JSON.parse(response.body, symbolize_names: true)
          expect(data[:auth_token]).to eq('secrettoken')
          expect(data[:account_sid]).to eq('AC123')
        end

        it "doesn't return auth_token and account_sid for agent" do
          create(:inbox_member, user: agent, inbox: twilio_inbox)
          get "/api/v1/accounts/#{account.id}/inboxes/#{twilio_inbox.id}",
              headers: agent.create_new_auth_token,
              as: :json
          expect(response).to have_http_status(:success)
          data = JSON.parse(response.body, symbolize_names: true)
          expect(data[:auth_token]).to be_nil
          expect(data[:account_sid]).to be_nil
        end
      end

      it 'fetch API inbox without hmac token when agent' do
        api_channel = create(:channel_api, account: account)
        api_inbox = create(:inbox, channel: api_channel, account: account)
        create(:inbox_member, user: agent, inbox: api_inbox)

        get "/api/v1/accounts/#{account.id}/inboxes/#{api_inbox.id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)

        data = JSON.parse(response.body, symbolize_names: true)

        expect(data[:hmac_token]).to be_nil
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/inboxes/{inbox.id}/assignable_agents' do
    let(:inbox) { create(:inbox, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/assignable_agents"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      before do
        create(:inbox_member, user: agent, inbox: inbox)
      end

      it 'returns all assignable inbox members along with administrators' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/assignable_agents",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_data = JSON.parse(response.body, symbolize_names: true)[:payload]
        expect(response_data.size).to eq(2)
        expect(response_data.pluck(:role)).to include('agent', 'administrator')
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/inboxes/{inbox.id}/campaigns' do
    let(:inbox) { create(:inbox, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/campaigns"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      let!(:campaign) { create(:campaign, account: account, inbox: inbox, trigger_rules: { url: 'https://test.com' }) }

      it 'returns unauthorized for agents' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/campaigns",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns all campaigns belonging to the inbox to administrators' do
        # create a random campaign
        create(:campaign, account: account, trigger_rules: { url: 'https://test.com' })
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/campaigns",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body.first[:id]).to eq(campaign.display_id)
        expect(body.length).to eq(1)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/inboxes/{inbox.id}/avatar' do
    let(:inbox) { create(:inbox, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/avatar"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      before do
        create(:inbox_member, user: agent, inbox: inbox)
        inbox.avatar.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
      end

      it 'delete inbox avatar for administrator user' do
        perform_enqueued_jobs(only: DeleteObjectJob) do
          delete "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/avatar",
                 headers: admin.create_new_auth_token,
                 as: :json
        end

        expect { inbox.avatar.attachment.reload }.to raise_error(ActiveRecord::RecordNotFound)
        expect(response).to have_http_status(:success)
      end

      it 'returns unauthorized for agent user' do
        delete "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/avatar",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/inboxes/:id' do
    let(:inbox) { create(:inbox, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }

      it 'deletes inbox' do
        expect(DeleteObjectJob).to receive(:perform_later).with(inbox, admin, anything).once

        delete "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
               headers: admin.create_new_auth_token,
               as: :json

        json_response = response.parsed_body

        expect(response).to have_http_status(:accepted)
        expect(json_response['message']).to eq('Your inbox deletion request will be processed in some time.')
        expect(json_response['id']).to eq(inbox.id)
        expect(json_response['deleting']).to be(true)
        expect(json_response['deleting_at']).to be_present
        expect(inbox.reload.deleting?).to be(true)
      end

      it 'deletes managed Virtual PBX voice inboxes synchronously and releases the phone number' do
        display_phone_number = '+17715550666'
        ingress_number = '056124100666'
        voice_channel = create(
          :channel_voice,
          :sipuni,
          account: account,
          phone_number: display_phone_number,
          provider_config: {
            number_ref: 'managed-delete-number-ref',
            app_ref: SecureRandom.uuid,
            trunk_ref: 'trunk-sipuni-onelink-out',
            routing_mode: 'operator',
            operator_agent_aor: 'sip:666@ats01.kz.sipuni.com',
            provider_kind: 'sipuni',
            display_phone_number: display_phone_number,
            provider_account_number: ingress_number,
            ingress_number: ingress_number,
            managed_by: 'onelink',
            ownership_status: 'local'
          }
        )
        voice_inbox = voice_channel.inbox
        number_binding = voice_inbox.telephony_number_binding
        number_binding.update!(
          managed_by: 'onelink',
          ownership_status: 'local',
          phone_number: ingress_number,
          display_phone_number: display_phone_number,
          provider_account_number: ingress_number,
          ingress_number: ingress_number,
          trunk_ref: 'trunk-sipuni-onelink-out'
        )

        expect(DeleteObjectJob).not_to receive(:perform_later)

        delete "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}",
               params: { remote_commit: false },
               headers: admin.create_new_auth_token,
               as: :json

        json_response = response.parsed_body

        expect(response).to have_http_status(:accepted)
        expect(json_response).to include(
          'id' => voice_inbox.id,
          'deleting' => false,
          'deleted' => true,
          'deleted_inbox_id' => voice_inbox.id,
          'remote_commit' => false
        )
        expect(Inbox.exists?(voice_inbox.id)).to be(false)
        expect(Channel::Voice.exists?(voice_channel.id)).to be(false)
        expect(Telephony::NumberBinding.exists?(number_binding.id)).to be(false)

        replacement_channel = create(
          :channel_voice,
          :sipuni,
          account: account,
          phone_number: display_phone_number,
          provider_config: {
            number_ref: 'managed-delete-replacement-number-ref',
            routing_mode: 'operator',
            operator_agent_aor: 'sip:667@ats01.kz.sipuni.com'
          }
        )
        expect(replacement_channel.phone_number).to eq(display_phone_number)
      end

      it 'runs remote cleanup by default for managed Virtual PBX voice inboxes' do
        display_phone_number = '+17715550667'
        ingress_number = '056124100667'
        voice_channel = create(
          :channel_voice,
          :sipuni,
          account: account,
          phone_number: display_phone_number,
          provider_config: {
            number_ref: 'managed-remote-delete-number-ref',
            app_ref: SecureRandom.uuid,
            trunk_ref: 'trunk-sipuni-onelink-out',
            routing_mode: 'operator',
            operator_agent_aor: 'sip:667@ats01.kz.sipuni.com',
            provider_kind: 'sipuni',
            display_phone_number: display_phone_number,
            provider_account_number: ingress_number,
            ingress_number: ingress_number,
            managed_by: 'onelink',
            ownership_status: 'local'
          }
        )
        voice_inbox = voice_channel.inbox
        voice_inbox.telephony_number_binding.update!(
          managed_by: 'onelink',
          ownership_status: 'local',
          phone_number: ingress_number,
          display_phone_number: display_phone_number,
          provider_account_number: ingress_number,
          ingress_number: ingress_number,
          trunk_ref: 'trunk-sipuni-onelink-out'
        )
        expect(DeleteObjectJob).not_to receive(:perform_later)

        delete "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}",
               headers: admin.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body).to include(
          'id' => voice_inbox.id,
          'deleted' => true,
          'remote_commit' => false
        )
        expect(Inbox.exists?(voice_inbox.id)).to be(false)
        expect(Channel::Voice.exists?(voice_channel.id)).to be(false)
      end

      it 'blocks reference Virtual PBX voice inbox deletion instead of queueing generic deletion' do
        voice_channel = create(
          :channel_voice,
          :sipuni,
          account: account,
          phone_number: '+17775550668',
          provider_config: {
            number_ref: 'sipuni-internal-asterisk-056124100668',
            app_ref: SecureRandom.uuid,
            trunk_ref: 'trunk-sipuni-onelink-out',
            routing_mode: 'operator',
            operator_agent_aor: 'sip:668@ats01.kz.sipuni.com',
            provider_kind: 'sipuni',
            display_phone_number: '+17775550668',
            ingress_number: '056124100668'
          }
        )
        voice_inbox = voice_channel.inbox
        voice_inbox.telephony_number_binding.update!(
          managed_by: nil,
          ownership_status: 'legacy_reference',
          phone_number: '056124100668',
          display_phone_number: '+17775550668',
          ingress_number: '056124100668',
          metadata: { provider_kind: 'sipuni', source: 'sipuni_internal_asterisk_gateway' }
        )

        expect(DeleteObjectJob).not_to receive(:perform_later)

        delete "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}",
               headers: admin.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to include('code' => 'TELEPHONY_DELETE_FAILED')
        expect(response.parsed_body.dig('payload', 'errors').map { |error| error['code'] }).to include('managed_ownership_required')
        expect(Inbox.exists?(voice_inbox.id)).to be(true)
        expect(Channel::Voice.exists?(voice_channel.id)).to be(true)
      end

      it 'includes channel deletion state for WhatsApp Web inboxes' do
        with_modified_env(
          'EVOLUTION_API_URL' => 'https://evolution.example.com',
          'EVOLUTION_API_KEY' => 'test-api-key',
          'FRONTEND_URL' => 'https://app.example.com'
        ) do
          whatsapp_inbox = create(:channel_whatsapp_web, account: account).inbox
          expect(DeleteObjectJob).to receive(:perform_later).with(whatsapp_inbox, admin, anything).once

          delete "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}",
                 headers: admin.create_new_auth_token,
                 as: :json

          json_response = response.parsed_body

          expect(response).to have_http_status(:accepted)
          expect(json_response['id']).to eq(whatsapp_inbox.id)
          expect(json_response['deleting']).to be(true)
          expect(json_response['lifecycle_state']).to eq('deleting')
          expect(json_response['connection_state']).to eq('close')
        end
      end

      it 'includes channel deletion state for Telegram Personal inboxes' do
        telegram_inbox = create(:channel_telegram_personal, account: account).inbox
        expect(DeleteObjectJob).to receive(:perform_later).with(telegram_inbox, admin, anything).once

        delete "/api/v1/accounts/#{account.id}/inboxes/#{telegram_inbox.id}",
               headers: admin.create_new_auth_token,
               as: :json

        json_response = response.parsed_body

        expect(response).to have_http_status(:accepted)
        expect(json_response['id']).to eq(telegram_inbox.id)
        expect(json_response['deleting']).to be(true)
        expect(json_response['channel_type']).to eq('Channel::TelegramPersonal')
        expect(json_response['lifecycle_state']).to eq('disconnected')
        expect(json_response['connection_state']).to eq('disconnected')
      end

      it 'keeps pending deletion inboxes out of the index response' do
        deleting_inbox = create(:inbox, account: account)
        deleting_inbox.mark_pending_deletion!

        get "/api/v1/accounts/#{account.id}/inboxes",
            headers: admin.create_new_auth_token,
            as: :json

        payload_ids = response.parsed_body['payload'].pluck('id')

        expect(response).to have_http_status(:success)
        expect(payload_ids).not_to include(deleting_inbox.id)
      end

      it 'is unable to delete inbox of another account' do
        other_account = create(:account)
        other_inbox = create(:inbox, account: other_account)

        delete "/api/v1/accounts/#{account.id}/inboxes/#{other_inbox.id}",
               headers: admin.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:not_found)
      end

      it 'is unable to delete inbox as agent' do
        agent = create(:user, account: account, role: :agent)

        delete "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/inboxes' do
    let(:inbox) { create(:inbox, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/inboxes"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:valid_params) { { name: 'test', channel: { type: 'web_widget', website_url: 'test.com' } } }

      it 'will not create inbox for agent' do
        agent = create(:user, account: account, role: :agent)

        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: agent.create_new_auth_token,
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'creates a webwidget inbox when administrator' do
        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: admin.create_new_auth_token,
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(response.body).to include('test.com')
      end

      it 'creates a email inbox when administrator' do
        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: admin.create_new_auth_token,
             params: { name: 'test', channel: { type: 'email', email: 'test@test.com' } },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('test@test.com')
      end

      it 'creates an api inbox when administrator' do
        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: admin.create_new_auth_token,
             params: { name: 'API Inbox', channel: { type: 'api', webhook_url: 'http://test.com' } },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('API Inbox')
      end

      it 'persists top-level Janus SIP voice channel parameters for native voice inbox creation' do
        account.enable_features!('channel_voice')
        phone_number = "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}"

        expect do
          post "/api/v1/accounts/#{account.id}/inboxes",
               headers: admin.create_new_auth_token,
               params: {
                 name: 'Sipuni Voice Inbox',
                 phone_number: phone_number,
                 provider: 'sipuni',
                 provider_config: {
                   number_ref: 'number-ref-top-level',
                   routing_mode: 'operator',
                   operator_agent_aor: 'sip:1001@example.test',
                   fallback_mode: 'ai',
                   ai_app_ref: 'ai-fallback-app-ref'
                 },
                 channel: { type: 'voice' }
               },
               as: :json
        end.to change(Inbox, :count).by(1)
                                    .and change(Channel::Voice, :count).by(1)
                                                                       .and change(Telephony::NumberBinding, :count).by(1)

        expect(response).to have_http_status(:success)
        voice_channel = Channel::Voice.find_by!(phone_number: phone_number)
        expect(voice_channel).to have_attributes(provider: 'sipuni')
        expect(voice_channel.provider_config).to include(
          'number_ref' => 'number-ref-top-level',
          'routing_mode' => 'operator',
          'operator_agent_aor' => 'sip:1001@example.test',
          'fallback_mode' => 'ai',
          'ai_app_ref' => 'ai-fallback-app-ref'
        )

        number_binding = voice_channel.inbox.telephony_number_binding
        expect(number_binding).to have_attributes(
          number_ref: 'number-ref-top-level',
          phone_number: phone_number,
          app_ref: nil,
          trunk_ref: nil
        )
        expect(number_binding.routing_policy).to have_attributes(
          mode: 'operator',
          operator_agent_aor: 'sip:1001@example.test',
          fallback_mode: 'ai',
          ai_app_ref: 'ai-fallback-app-ref',
          ai_enabled: true
        )
      end

      it 'creates one Janus SIP voice inbox that is ready for both operator and Captain routing' do
        account.enable_features!('channel_voice')
        assistant = create(:captain_assistant, account: account)
        phone_number = "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}"

        expect do
          post "/api/v1/accounts/#{account.id}/inboxes",
               headers: admin.create_new_auth_token,
               params: {
                 name: 'Unified Voice Inbox',
                 phone_number: phone_number,
                 provider: 'sipuni',
                 provider_config: {
                   number_ref: 'number-ref-unified',
                   app_route_app_ref: 'fallback-app-ref-unified',
                   routing_mode: 'operator',
                   operator_agent_aor: 'sip:1001@example.test',
                   fallback_mode: 'app',
                   onelink_ai_app_ref: 'captain-ai-app-ref-unified',
                   captain_assistant_id: assistant.id
                 },
                 channel: { type: 'voice' }
               },
               as: :json
        end.to change(CaptainInbox, :count).by(1)

        expect(response).to have_http_status(:success)
        voice_channel = Channel::Voice.find_by!(phone_number: phone_number)
        number_binding = voice_channel.inbox.telephony_number_binding
        policy = number_binding.routing_policy

        expect(CaptainInbox.find_by(inbox: voice_channel.inbox)).to have_attributes(captain_assistant_id: assistant.id)
        expect(policy).to have_attributes(
          mode: 'operator',
          operator_agent_aor: 'sip:1001@example.test',
          ai_enabled: true,
          ai_deployment_mode: 'onelink_managed',
          onelink_ai_app_ref: 'captain-ai-app-ref-unified',
          fallback_mode: 'app',
          captain_assistant_id: assistant.id
        )
      end

      it 'does not create a main channel inbox when the account main channel limit is reached' do
        account.update!(limits: { non_web_inboxes: 1 })
        create(:channel_api, account: account)

        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: admin.create_new_auth_token,
             params: { name: 'API Inbox 2', channel: { type: 'api', webhook_url: 'http://test2.com' } },
             as: :json

        expect(response).to have_http_status(:payment_required)
        expect(response.parsed_body['error']).to include('Account main channel limit exceeded')
      end

      it 'does not create a telegram personal inbox when the account main channel limit is reached' do
        account.update!(limits: { non_web_inboxes: 1 })
        create(:channel_api, account: account)

        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: admin.create_new_auth_token,
             params: {
               name: 'Telegram Personal Inbox',
               channel: {
                 type: 'telegram_personal',
                 api_id: 123_456,
                 api_hash: SecureRandom.hex(16),
                 phone_number: '+77066318623'
               }
             },
             as: :json

        expect(response).to have_http_status(:payment_required)
        expect(response.parsed_body['error']).to include('Account main channel limit exceeded')
      end

      it 'creates a whatsapp web inbox when administrator' do
        with_modified_env(
          'EVOLUTION_API_URL' => 'https://evolution.example.com',
          'EVOLUTION_API_KEY' => 'test-api-key',
          'FRONTEND_URL' => 'https://app.example.com'
        ) do
          post "/api/v1/accounts/#{account.id}/inboxes",
               headers: admin.create_new_auth_token,
               params: {
                 channel: {
                   type: 'whatsapp_web',
                   phone_number: '+77066318623',
                   conversation_pending: true,
                   history_lookback_days: 90,
                   ignore_jids: ['15550001111@s.whatsapp.net'],
                   sign_messages: true,
                   sign_delimiter: '\\n--\\n',
                   import_contacts: true,
                   import_messages: true,
                   sync_labels: false
                 }
               },
               as: :json

          expect(response).to have_http_status(:success)
          expect(response.parsed_body['name']).to eq('77066318623')
          expect(response.parsed_body['channel_type']).to eq('Channel::WhatsappWeb')
          expect(response.parsed_body['phone_number']).to eq('+77066318623')
          expect(response.parsed_body['conversation_pending']).to be(true)
          expect(response.parsed_body['history_lookback_days']).to eq(90)
          expect(response.parsed_body['ignore_jids']).to eq(['15550001111@s.whatsapp.net'])
          expect(response.parsed_body['sign_messages']).to be(true)
          expect(response.parsed_body['sign_delimiter']).to eq('\\n--\\n')
          expect(response.parsed_body['sync_labels']).to be(false)
          expect(response.parsed_body.dig('additional_attributes', 'evolution', 'instance_name')).to be_present
        end
      end

      it 'creates a line inbox when administrator' do
        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: admin.create_new_auth_token,
             params: { name: 'Line Inbox',
                       channel: { type: 'line', line_channel_id: SecureRandom.uuid, line_channel_secret: SecureRandom.uuid,
                                  line_channel_token: SecureRandom.uuid } },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Line Inbox')
        expect(response.body).to include('callback_webhook_url')
      end

      it 'creates a sms inbox when administrator' do
        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: admin.create_new_auth_token,
             params: { name: 'Sms Inbox',
                       channel: { type: 'sms', phone_number: '+123456789', provider_config: { test: 'test' } } },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.body).to include('Sms Inbox')
        expect(response.body).to include('+123456789')
      end

      it 'creates the webwidget inbox that allow messages after conversation is resolved' do
        post "/api/v1/accounts/#{account.id}/inboxes",
             headers: admin.create_new_auth_token,
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        expect(json_response['allow_messages_after_resolved']).to be true
      end
    end
  end

  describe 'WhatsApp Web lifecycle endpoints' do
    around do |example|
      with_modified_env(
        'EVOLUTION_API_URL' => 'https://evolution.example.com',
        'EVOLUTION_API_KEY' => 'test-api-key',
        'FRONTEND_URL' => 'https://app.example.com'
      ) do
        example.run
      end
    end

    let(:admin) { create(:user, account: account, role: :administrator) }
    let(:channel) { create(:channel_whatsapp_web, account: account) }
    let(:inbox) { channel.inbox }

    describe 'POST /api/v1/accounts/:account_id/inboxes/:id/refresh_whatsapp_web_qr' do
      it 'syncs status when called with status_only without returning qr payload by default' do
        expect_any_instance_of(Channel::WhatsappWeb).to receive(:sync_connection_state!) do |instance|
          instance.update!(
            lifecycle_state: 'connected',
            connection_state: 'open',
            qr_code: { 'base64' => 'large-qr-payload' },
            last_synced_at: Time.current
          )
        end
        expect_any_instance_of(Channel::WhatsappWeb).not_to receive(:refresh_qr!)

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/refresh_whatsapp_web_qr",
             headers: admin.create_new_auth_token,
             params: { status_only: true },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'status')).to eq('connected')
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode')).to be_nil
      end

      it 'returns qr payload during status sync when explicitly requested' do
        expect_any_instance_of(Channel::WhatsappWeb).to receive(:sync_connection_state!) do |instance|
          instance.update!(
            lifecycle_state: 'waiting_for_qr',
            connection_state: 'connecting',
            qr_code: { 'base64' => 'large-qr-payload' },
            last_synced_at: Time.current
          )
        end

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/refresh_whatsapp_web_qr",
             headers: admin.create_new_auth_token,
             params: { status_only: true, include_qr_code: true },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode', 'base64')).to eq('large-qr-payload')
      end

      it 'recovers a missing QR artifact during setup status polling when QR payload is requested' do
        expect_any_instance_of(Channel::WhatsappWeb).to receive(:sync_connection_state!) do |instance|
          instance.update!(
            lifecycle_state: 'waiting_for_qr',
            connection_state: 'connecting',
            qr_code: {},
            last_synced_at: Time.current
          )
        end
        expect_any_instance_of(Channel::WhatsappWeb).to receive(:refresh_qr!).with(artifact_type: 'qr') do |instance|
          instance.update!(
            lifecycle_state: 'qr_ready',
            connection_state: 'connecting',
            qr_code: { 'artifact_type' => 'qr', 'base64' => 'recovered-qr', 'code' => 'recovered-code' },
            last_synced_at: Time.current
          )
        end

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/refresh_whatsapp_web_qr",
             headers: admin.create_new_auth_token,
             params: { status_only: true, include_qr_code: true },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'status')).to eq('qr_ready')
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode', 'base64')).to eq('recovered-qr')
      end

      it 'does not recover a new QR while a scanned artifact is still connecting' do
        expect_any_instance_of(Channel::WhatsappWeb).to receive(:sync_connection_state!) do |instance|
          instance.update!(
            lifecycle_state: 'qr_scanned',
            connection_state: 'connecting',
            qr_code: {},
            sync_state: instance.sync_state_payload.merge(
              'qr_generated_at' => nil,
              'auth_artifact_scanned_at' => Time.current.iso8601
            ),
            last_synced_at: Time.current
          )
        end
        expect_any_instance_of(Channel::WhatsappWeb).not_to receive(:refresh_qr!)

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/refresh_whatsapp_web_qr",
             headers: admin.create_new_auth_token,
             params: { status_only: true, include_qr_code: true },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'status')).to eq('qr_scanned')
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode')).to be_nil
      end

      it 'passes explicit QR artifact type to the provider' do
        expect_any_instance_of(Channel::WhatsappWeb).to receive(:refresh_qr!)
          .with(artifact_type: 'qr') do |instance|
            instance.update!(
              lifecycle_state: 'qr_ready',
              connection_state: 'connecting',
              qr_code: { 'artifact_type' => 'qr', 'base64' => 'fresh-qr', 'code' => 'qr-code-value' },
              last_synced_at: Time.current
            )
          end

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/refresh_whatsapp_web_qr",
             headers: admin.create_new_auth_token,
             params: { artifact_type: 'qr' },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode', 'artifact_type')).to eq('qr')
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode', 'pairingCode')).to be_nil
      end

      it 'passes explicit pairing-code artifact type to the provider' do
        expect_any_instance_of(Channel::WhatsappWeb).to receive(:refresh_qr!)
          .with(artifact_type: 'code') do |instance|
            instance.update!(
              lifecycle_state: 'qr_ready',
              connection_state: 'connecting',
              qr_code: { 'artifact_type' => 'pairing_code', 'pairingCode' => 'ABCD1234' },
              last_synced_at: Time.current
            )
          end

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/refresh_whatsapp_web_qr",
             headers: admin.create_new_auth_token,
             params: { artifact_type: 'code' },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode', 'artifact_type')).to eq('pairing_code')
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode', 'base64')).to be_nil
      end

      it 'returns the degraded inbox state when status polling fails' do
        allow_any_instance_of(Channel::WhatsappWeb).to receive(:sync_connection_state!)
          .and_raise(StandardError, 'Evolution connection unavailable')

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/refresh_whatsapp_web_qr",
             headers: admin.create_new_auth_token,
             params: { status_only: true },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'status')).to eq('failed')
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'last_error')).to eq('Evolution connection unavailable')
        expect(channel.reload.last_error).to eq('Evolution connection unavailable')
      end

      it 'returns accepted without touching the provider when the inbox is deleting' do
        inbox.mark_pending_deletion!

        expect_any_instance_of(Channel::WhatsappWeb).not_to receive(:sync_connection_state!)

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/refresh_whatsapp_web_qr",
             headers: admin.create_new_auth_token,
             params: { status_only: true },
             as: :json

        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body['deleting']).to eq(true)
        expect(response.parsed_body['lifecycle_state']).to eq('deleting')
      end
    end

    describe 'POST /api/v1/accounts/:account_id/inboxes/:id/reconnect_whatsapp_web' do
      it 'reconnects the runtime session' do
        expect_any_instance_of(Channel::WhatsappWeb).to receive(:reconnect!) do |instance|
          instance.update!(lifecycle_state: 'waiting_for_qr', connection_state: 'connecting', last_synced_at: Time.current)
        end

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/reconnect_whatsapp_web",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'status')).to eq('waiting_for_qr')
      end

      it 'returns both qr and pairing code when reconnect requires new auth artifacts' do
        expect_any_instance_of(Channel::WhatsappWeb).to receive(:reconnect!) do |instance|
          instance.update!(
            lifecycle_state: 'qr_ready',
            connection_state: 'connecting',
            qr_code: {
              'base64' => 'fresh-qr',
              'pairingCode' => 'ABCD1234'
            },
            last_synced_at: Time.current
          )
        end

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/reconnect_whatsapp_web",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'status')).to eq('qr_ready')
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode', 'base64')).to eq('fresh-qr')
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode', 'pairingCode')).to eq('ABCD1234')
      end
    end

    describe 'POST /api/v1/accounts/:account_id/inboxes/:id/reauthorize_whatsapp_web' do
      it 'forces reauthorization and returns the fresh QR' do
        provider_service = instance_double(WhatsappWeb::Providers::EvolutionService)
        allow(WhatsappWeb::Providers::EvolutionService).to receive(:new).and_return(provider_service)
        expect(provider_service).to receive(:reauthorize!) do
          inbox.reload.channel.update!(
            lifecycle_state: 'qr_ready',
            connection_state: 'connecting',
            qr_code: { 'base64' => 'fresh-reauth-qr' },
            last_synced_at: Time.current
          )
        end

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/reauthorize_whatsapp_web",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'status')).to eq('qr_ready')
        expect(response.parsed_body.dig('additional_attributes', 'evolution', 'qrcode', 'base64')).to eq('fresh-reauth-qr')
      end
    end

    describe 'GET /api/v1/accounts/:account_id/inboxes/:id/whatsapp_web_diagnostics' do
      it 'returns provider diagnostics' do
        allow_any_instance_of(Channel::WhatsappWeb).to receive(:diagnostics).and_return(
          counts: { messages_missing_provider_message_id: 1 },
          samples: { provisional_contacts: [] }
        )

        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/whatsapp_web_diagnostics",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('counts', 'messages_missing_provider_message_id')).to eq(1)
      end
    end

    describe 'POST /api/v1/accounts/:account_id/inboxes/:id/disconnect_whatsapp_web' do
      it 'rejects non-whatsapp-web inboxes' do
        non_whatsapp_inbox = create(:inbox, account: account)

        post "/api/v1/accounts/#{account.id}/inboxes/#{non_whatsapp_inbox.id}/disconnect_whatsapp_web",
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:bad_request)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/inboxes/:id' do
    let(:inbox) { create(:inbox, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let!(:portal) { create(:portal, account_id: account.id) }
      let(:valid_params) { { name: 'new test inbox', enable_auto_assignment: false, portal_id: portal.id } }

      it 'will not update inbox for agent' do
        agent = create(:user, account: account, role: :agent)

        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              headers: agent.create_new_auth_token,
              params: valid_params,
              as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'updates inbox when administrator' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              headers: admin.create_new_auth_token,
              params: valid_params,
              as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(inbox.reload.enable_auto_assignment).to be_falsey
        expect(inbox.reload.portal_id).to eq(portal.id)
        expect(response.parsed_body['name']).to eq 'new test inbox'
      end

      it 'updates api inbox when administrator' do
        api_channel = create(:channel_api, account: account)
        api_inbox = create(:inbox, channel: api_channel, account: account)

        patch "/api/v1/accounts/#{account.id}/inboxes/#{api_inbox.id}",
              headers: admin.create_new_auth_token,
              params: { enable_auto_assignment: false, channel: { webhook_url: 'webhook.test', selected_feature_flags: [] } },
              as: :json

        expect(response).to have_http_status(:success)
        expect(api_inbox.reload.enable_auto_assignment).to be_falsey
        expect(api_channel.reload.webhook_url).to eq('webhook.test')
      end

      it 'updates whatsapp inbox when administrator' do
        stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook').to_return(status: 200, body: '', headers: {})
        stub_request(:get, 'https://waba.360dialog.io/v1/configs/templates').to_return(status: 200, body: '', headers: {})
        whatsapp_channel = create(:channel_whatsapp, account: account)
        whatsapp_inbox = create(:inbox, channel: whatsapp_channel, account: account)
        whatsapp_channel.prompt_reauthorization!

        expect(whatsapp_channel).to be_reauthorization_required

        patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}",
              headers: admin.create_new_auth_token,
              params: { enable_auto_assignment: false, channel: { provider_config: { api_key: 'new_key' } } },
              as: :json

        expect(response).to have_http_status(:success)
        expect(whatsapp_inbox.reload.enable_auto_assignment).to be_falsey
        expect(whatsapp_channel.reload.provider_config['api_key']).to eq('new_key')
        expect(whatsapp_channel.reload).not_to be_reauthorization_required
      end

      it 'stores token health when manually updating a WhatsApp Cloud API token' do
        token_health = {
          'status' => 'healthy',
          'waba_access' => true,
          'phone_number_access' => true
        }
        token_inspection = instance_double(Whatsapp::TokenInspectionService, perform: token_health)
        allow(Whatsapp::TokenInspectionService).to receive(:new).with(
          access_token: 'new_cloud_token',
          waba_id: 'waba-1',
          phone_number_id: 'phone-1'
        ).and_return(token_inspection)

        stub_request(:get, 'https://graph.facebook.com/v22.0/waba-1/message_templates')
          .to_return(status: 200, body: { data: [] }.to_json, headers: { 'Content-Type' => 'application/json' })

        whatsapp_channel = create(
          :channel_whatsapp,
          account: account,
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false
        )
        whatsapp_channel.update!(
          provider_config: {
            'api_key' => 'old_cloud_token',
            'business_account_id' => 'waba-1',
            'phone_number_id' => 'phone-1',
            'source' => 'embedded_signup'
          }
        )
        whatsapp_inbox = whatsapp_channel.inbox

        patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}",
              headers: admin.create_new_auth_token,
              params: { channel: { provider_config: { api_key: 'new_cloud_token' } } },
              as: :json

        expect(response).to have_http_status(:success)
        expect(whatsapp_channel.reload.provider_config).to include(
          'api_key' => 'new_cloud_token',
          'business_account_id' => 'waba-1',
          'phone_number_id' => 'phone-1',
          Channel::Whatsapp::TOKEN_HEALTH_CONFIG_KEY => hash_including('status' => 'healthy')
        )
      end

      it 'merges provider config when updating a voice inbox webhook token' do
        provider_connection = create(:telephony_provider_connection, account: account, provider_kind: 'sipuni')
        voice_channel = create(
          :channel_voice,
          account: account,
          provider: 'sipuni',
          provider_config: {
            provider_kind: 'sipuni',
            provider_connection_id: provider_connection.id,
            number_ref: 'sipuni-number-ref',
            routing_mode: 'operator',
            operator_distribution_mode: 'broadcast'
          }
        )
        voice_inbox = voice_channel.inbox

        patch "/api/v1/accounts/#{account.id}/inboxes/#{voice_inbox.id}",
              headers: admin.create_new_auth_token,
              params: {
                channel: {
                  provider_config: {
                    sipuni_events_webhook_token: 'new-webhook-token'
                  }
                }
              },
              as: :json

        expect(response).to have_http_status(:success)
        expect(voice_channel.reload.provider_config).to include(
          'provider_connection_id' => provider_connection.id,
          'number_ref' => 'sipuni-number-ref',
          'sipuni_events_webhook_token' => 'new-webhook-token'
        )
      end

      it 'rejects runtime identity updates for whatsapp web inboxes' do
        with_modified_env(
          'EVOLUTION_API_URL' => 'https://evolution.example.com',
          'EVOLUTION_API_KEY' => 'test-api-key',
          'FRONTEND_URL' => 'https://app.example.com'
        ) do
          whatsapp_web_channel = create(:channel_whatsapp_web, account: account)
          whatsapp_web_inbox = whatsapp_web_channel.inbox

          patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_web_inbox.id}",
                headers: admin.create_new_auth_token,
                params: { channel: { phone_number: '+15550001111' } },
                as: :json

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body['message']).to include('Phone number cannot be changed after the inbox is created')
          expect(response.parsed_body['attributes']).to include('phone_number')
          expect(whatsapp_web_channel.reload.phone_number).not_to eq('+15550001111')
        end
      end

      it 'updates native whatsapp web settings when administrator' do
        with_modified_env(
          'EVOLUTION_API_URL' => 'https://evolution.example.com',
          'EVOLUTION_API_KEY' => 'test-api-key',
          'FRONTEND_URL' => 'https://app.example.com'
        ) do
          whatsapp_web_channel = create(:channel_whatsapp_web, account: account)
          whatsapp_web_inbox = whatsapp_web_channel.inbox

          patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_web_inbox.id}",
                headers: admin.create_new_auth_token,
                params: {
                  channel: {
                    conversation_pending: true,
                    history_lookback_days: 120,
                    ignore_jids: %w[15550001111@s.whatsapp.net 15550002222@s.whatsapp.net],
                    sign_messages: true,
                    sign_delimiter: '\\n--\\n',
                    import_contacts: false,
                    import_messages: false,
                    sync_labels: false
                  }
                },
                as: :json

          expect(response).to have_http_status(:success)
          expect(response.parsed_body['conversation_pending']).to be(true)
          expect(response.parsed_body['history_lookback_days']).to eq(120)
          expect(response.parsed_body['ignore_jids']).to eq(%w[15550001111@s.whatsapp.net 15550002222@s.whatsapp.net])
          expect(response.parsed_body['sign_messages']).to be(true)
          expect(response.parsed_body['sign_delimiter']).to eq('\\n--\\n')
          expect(response.parsed_body['import_contacts']).to be(false)
          expect(response.parsed_body['import_messages']).to be(false)
          expect(response.parsed_body['sync_labels']).to be(false)

          whatsapp_web_channel.reload
          expect(whatsapp_web_channel.conversation_pending).to be(true)
          expect(whatsapp_web_channel.history_lookback_days).to eq(120)
          expect(whatsapp_web_channel.ignore_jids).to eq(%w[15550001111@s.whatsapp.net 15550002222@s.whatsapp.net])
          expect(whatsapp_web_channel.sign_messages).to be(true)
          expect(whatsapp_web_channel.import_contacts).to be(false)
          expect(whatsapp_web_channel.import_messages).to be(false)
          expect(whatsapp_web_channel.sync_labels).to be(false)
        end
      end

      it 'accepts zero lookback days for unlimited whatsapp web history' do
        with_modified_env(
          'EVOLUTION_API_URL' => 'https://evolution.example.com',
          'EVOLUTION_API_KEY' => 'test-api-key',
          'FRONTEND_URL' => 'https://app.example.com'
        ) do
          whatsapp_web_channel = create(:channel_whatsapp_web, account: account, history_lookback_days: 30)
          whatsapp_web_inbox = whatsapp_web_channel.inbox

          patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_web_inbox.id}",
                headers: admin.create_new_auth_token,
                params: {
                  channel: {
                    history_lookback_days: 0
                  }
                },
                as: :json

          expect(response).to have_http_status(:success)
          expect(response.parsed_body['history_lookback_days']).to eq(0)
          expect(whatsapp_web_channel.reload.history_lookback_days).to eq(0)
        end
      end

      it 'updates twitter inbox when administrator' do
        twitter_channel = create(:channel_twitter_profile, account: account, tweets_enabled: true)
        twitter_inbox = create(:inbox, channel: twitter_channel, account: account)

        patch "/api/v1/accounts/#{account.id}/inboxes/#{twitter_inbox.id}",
              headers: admin.create_new_auth_token,
              params: { channel: { tweets_enabled: false } },
              as: :json

        expect(response).to have_http_status(:success)
        expect(twitter_channel.reload.tweets_enabled).to be(false)
      end

      it 'updates email inbox when administrator' do
        email_channel = create(:channel_email, account: account)
        email_inbox = create(:inbox, channel: email_channel, account: account)

        patch "/api/v1/accounts/#{account.id}/inboxes/#{email_inbox.id}",
              headers: admin.create_new_auth_token,
              params: { enable_auto_assignment: false, channel: { email: 'emailtest@email.test' } },
              as: :json

        expect(response).to have_http_status(:success)
        expect(email_inbox.reload.enable_auto_assignment).to be_falsey
        expect(email_channel.reload.email).to eq('emailtest@email.test')
      end

      it 'updates twilio sms inbox when administrator' do
        twilio_sms_channel = create(:channel_twilio_sms, account: account)
        twilio_sms_inbox = create(:inbox, channel: twilio_sms_channel, account: account)
        expect(twilio_sms_inbox.reload.channel.account_sid).not_to eq('account_sid')
        expect(twilio_sms_inbox.reload.channel.auth_token).not_to eq('new_auth_token')

        patch "/api/v1/accounts/#{account.id}/inboxes/#{twilio_sms_inbox.id}",
              headers: admin.create_new_auth_token,
              params: { channel: { account_sid: 'account_sid', auth_token: 'new_auth_token' } },
              as: :json

        expect(response).to have_http_status(:success)
        expect(twilio_sms_inbox.reload.channel.account_sid).to eq('account_sid')
        expect(twilio_sms_inbox.reload.channel.auth_token).to eq('new_auth_token')
      end

      it 'updates email inbox with imap when administrator' do
        email_channel = create(:channel_email, account: account)
        email_inbox = create(:inbox, channel: email_channel, account: account)

        imap_connection = instance_double(Net::IMAP, disconnected?: false)
        allow(Net::IMAP).to receive(:new)
          .with('imap.gmail.com', port: 993, ssl: true)
          .and_return(imap_connection)
        allow(imap_connection).to receive(:authenticate).with('plain', 'imaptest@gmail.com', nil)
        allow(imap_connection).to receive(:disconnect)

        patch "/api/v1/accounts/#{account.id}/inboxes/#{email_inbox.id}",
              headers: admin.create_new_auth_token,
              params: {
                channel: {
                  imap_enabled: true,
                  imap_address: 'imap.gmail.com',
                  imap_port: 993,
                  imap_login: 'imaptest@gmail.com',
                  imap_authentication: 'plain'
                }
              },
              as: :json

        expect(response).to have_http_status(:success)
        expect(email_channel.reload.imap_enabled).to be true
        expect(email_channel.reload.imap_address).to eq('imap.gmail.com')
        expect(email_channel.reload.imap_port).to eq(993)
        expect(email_channel.reload.imap_authentication).to eq('plain')
      end

      it 'updates avatar when administrator' do
        # no avatar before upload
        expect(inbox.avatar.attached?).to be(false)
        file = fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png')
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: valid_params.merge(avatar: file),
              headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        inbox.reload
        expect(inbox.avatar.attached?).to be(true)
      end

      it 'updates working hours when administrator' do
        params = {
          working_hours: [{ 'day_of_week' => 0, 'open_hour' => 9, 'open_minutes' => 0, 'close_hour' => 17, 'close_minutes' => 0 }],
          working_hours_enabled: true,
          out_of_office_message: 'hello'
        }
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: valid_params.merge(params),
              headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        inbox.reload
        expect(inbox.reload.weekly_schedule.find { |schedule| schedule['day_of_week'] == 0 }['open_hour']).to eq 9
      end

      it 'updates the webwidget inbox to disallow the messages after conversation is resolved' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              headers: admin.create_new_auth_token,
              params: valid_params.merge({ allow_messages_after_resolved: false }),
              as: :json

        expect(response).to have_http_status(:success)
        expect(inbox.reload.allow_messages_after_resolved).to be_falsey
      end
    end

    context 'when an authenticated user updates email inbox' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:email_channel) { create(:channel_email, account: account) }
      let(:email_inbox) { create(:inbox, channel: email_channel, account: account) }

      it 'updates smtp configuration with starttls encryption' do
        smtp_connection = double
        allow(smtp_connection).to receive(:open_timeout=).and_return(10)
        allow(smtp_connection).to receive(:start).and_return(true)
        allow(smtp_connection).to receive(:finish).and_return(true)
        allow(smtp_connection).to receive(:respond_to?).and_return(true)
        expect(smtp_connection).to receive(:enable_starttls_auto) do |context|
          expect(context.verify_mode).to eq(OpenSSL::SSL::VERIFY_PEER)
          expect(context.verify_hostname).to be(true)
        end
        allow(Net::SMTP).to receive(:new).and_return(smtp_connection)

        patch "/api/v1/accounts/#{account.id}/inboxes/#{email_inbox.id}",
              headers: admin.create_new_auth_token,
              params: {
                channel: {
                  smtp_enabled: true,
                  smtp_address: 'smtp.gmail.com',
                  smtp_port: 587,
                  smtp_login: 'smtptest@gmail.com',
                  smtp_enable_starttls_auto: true,
                  smtp_openssl_verify_mode: 'peer'
                }
              },
              as: :json

        expect(response).to have_http_status(:success)
        expect(email_channel.reload.smtp_enabled).to be true
        expect(email_channel.reload.smtp_address).to eq('smtp.gmail.com')
        expect(email_channel.reload.smtp_port).to eq(587)
        expect(email_channel.reload.smtp_enable_starttls_auto).to be true
        expect(email_channel.reload.smtp_openssl_verify_mode).to eq('peer')
      end

      it 'updates smtp configuration with ssl/tls encryption' do
        smtp_connection = double
        allow(smtp_connection).to receive(:open_timeout=).and_return(10)
        allow(smtp_connection).to receive(:start).and_return(true)
        allow(smtp_connection).to receive(:finish).and_return(true)
        allow(smtp_connection).to receive(:respond_to?).and_return(true)
        expect(smtp_connection).to receive(:enable_tls) do |context|
          expect(context.verify_mode).to eq(OpenSSL::SSL::VERIFY_NONE)
          expect(context.verify_hostname).to be(false)
        end
        allow(Net::SMTP).to receive(:new).and_return(smtp_connection)

        patch "/api/v1/accounts/#{account.id}/inboxes/#{email_inbox.id}",
              headers: admin.create_new_auth_token,
              params: {
                channel: {
                  smtp_enabled: true,
                  smtp_address: 'smtp.gmail.com',
                  smtp_login: 'smtptest@gmail.com',
                  smtp_port: 587,
                  smtp_enable_ssl_tls: true,
                  smtp_openssl_verify_mode: 'none'
                }
              },
              as: :json

        expect(response).to have_http_status(:success)
        expect(email_channel.reload.smtp_enabled).to be true
        expect(email_channel.reload.smtp_address).to eq('smtp.gmail.com')
        expect(email_channel.reload.smtp_port).to eq(587)
        expect(email_channel.reload.smtp_enable_ssl_tls).to be true
        expect(email_channel.reload.smtp_openssl_verify_mode).to eq('none')
      end

      it 'updates smtp configuration with authentication mechanism' do
        smtp_connection = double
        allow(smtp_connection).to receive(:open_timeout=).and_return(10)
        allow(smtp_connection).to receive(:start).and_return(true)
        allow(smtp_connection).to receive(:finish).and_return(true)
        allow(smtp_connection).to receive(:respond_to?).and_return(true)
        allow(smtp_connection).to receive(:enable_starttls_auto).and_return(true)
        allow(Net::SMTP).to receive(:new).and_return(smtp_connection)

        patch "/api/v1/accounts/#{account.id}/inboxes/#{email_inbox.id}",
              headers: admin.create_new_auth_token,
              params: {
                channel: {
                  smtp_enabled: true,
                  smtp_address: 'smtp.gmail.com',
                  smtp_port: 587,
                  smtp_email: 'smtptest@gmail.com',
                  smtp_authentication: 'plain'
                }
              },
              as: :json

        expect(response).to have_http_status(:success)
        expect(email_channel.reload.smtp_enabled).to be true
        expect(email_channel.reload.smtp_address).to eq('smtp.gmail.com')
        expect(email_channel.reload.smtp_port).to eq(587)
        expect(email_channel.reload.smtp_authentication).to eq('plain')
      end
    end

    context 'when handling CSAT configuration' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:admin_headers) { admin.create_new_auth_token }
      let(:inbox) { create(:inbox, account: account) }
      let(:csat_config) do
        {
          'display_type' => 'emoji',
          'message' => 'How would you rate your experience?',
          'survey_rules' => {
            'operator' => 'contains',
            'values' => %w[support help]
          }
        }
      end

      it 'successfully updates the inbox with CSAT configuration' do
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: {
                csat_survey_enabled: true,
                csat_config: csat_config
              },
              headers: admin_headers,
              as: :json

        expect(response).to have_http_status(:success)
      end

      context 'when CSAT is configured' do
        before do
          patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
                params: {
                  csat_survey_enabled: true,
                  csat_config: csat_config
                },
                headers: admin_headers,
                as: :json
        end

        it 'returns configured CSAT settings in inbox details' do
          get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              headers: admin_headers,
              as: :json

          expect(response).to have_http_status(:success)
          json_response = response.parsed_body
          expect(json_response['csat_survey_enabled']).to be true

          saved_config = json_response['csat_config']
          expect(saved_config).to be_present
          expect(saved_config['display_type']).to eq('emoji')
        end

        it 'returns configured CSAT message' do
          get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              headers: admin_headers,
              as: :json

          json_response = response.parsed_body
          saved_config = json_response['csat_config']
          expect(saved_config['message']).to eq('How would you rate your experience?')
        end

        it 'returns configured CSAT survey rules' do
          get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              headers: admin_headers,
              as: :json

          json_response = response.parsed_body
          saved_config = json_response['csat_config']
          expect(saved_config['survey_rules']['operator']).to eq('contains')
          expect(saved_config['survey_rules']['values']).to match_array(%w[support help])
        end

        it 'includes CSAT configuration in inbox list' do
          get "/api/v1/accounts/#{account.id}/inboxes",
              headers: admin_headers,
              as: :json

          expect(response).to have_http_status(:success)
          inbox_list = response.parsed_body
          found_inbox = inbox_list['payload'].find { |i| i['id'] == inbox.id }

          expect(found_inbox['csat_survey_enabled']).to be true
          expect(found_inbox['csat_config']).to be_present
          expect(found_inbox['csat_config']['display_type']).to eq('emoji')
        end
      end

      it 'successfully updates inbox with template configuration' do
        csat_config_with_template = csat_config.merge({
                                                        'template' => {
                                                          'name' => 'custom_survey_template',
                                                          'template_id' => '123456789',
                                                          'language' => 'en',
                                                          'created_at' => Time.current.iso8601
                                                        }
                                                      })

        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: {
                csat_survey_enabled: true,
                csat_config: csat_config_with_template
              },
              headers: admin_headers,
              as: :json

        expect(response).to have_http_status(:success)

        inbox.reload
        template_config = inbox.csat_config['template']
        expect(template_config).to be_present
        expect(template_config['name']).to eq('custom_survey_template')
        expect(template_config['template_id']).to eq('123456789')
        expect(template_config['language']).to eq('en')
      end

      it 'returns template configuration in inbox details' do
        csat_config_with_template = csat_config.merge({
                                                        'template' => {
                                                          'name' => 'custom_survey_template',
                                                          'template_id' => '123456789',
                                                          'language' => 'en',
                                                          'created_at' => Time.current.iso8601
                                                        }
                                                      })

        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: {
                csat_survey_enabled: true,
                csat_config: csat_config_with_template
              },
              headers: admin_headers,
              as: :json

        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
            headers: admin_headers,
            as: :json

        expect(response).to have_http_status(:success)
        json_response = response.parsed_body
        template_config = json_response['csat_config']['template']

        expect(template_config).to be_present
        expect(template_config['name']).to eq('custom_survey_template')
        expect(template_config['template_id']).to eq('123456789')
        expect(template_config['language']).to eq('en')
        expect(template_config['created_at']).to be_present
      end

      it 'removes template configuration when not provided in update' do
        # First set up template configuration
        csat_config_with_template = csat_config.merge({
                                                        'template' => {
                                                          'name' => 'custom_survey_template',
                                                          'template_id' => '123456789'
                                                        }
                                                      })

        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: {
                csat_survey_enabled: true,
                csat_config: csat_config_with_template
              },
              headers: admin_headers,
              as: :json

        # Then update without template
        patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
              params: {
                csat_survey_enabled: true,
                csat_config: csat_config.merge({ 'message' => 'Updated message' })
              },
              headers: admin_headers,
              as: :json

        expect(response).to have_http_status(:success)

        inbox.reload
        config = inbox.csat_config
        expect(config['message']).to eq('Updated message')
        expect(config['template']).to be_nil # Template should be removed when not provided
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/inboxes/{inbox.id}/agent_bot' do
    let(:inbox) { create(:inbox, account: account) }

    before do
      create(:inbox_member, user: agent, inbox: inbox)
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/agent_bot"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns empty when no agent bot is present' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/agent_bot",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        inbox_data = JSON.parse(response.body, symbolize_names: true)
        expect(inbox_data[:agent_bot].blank?).to be(true)
      end

      it 'returns the agent bot attached to the inbox' do
        agent_bot = create(:agent_bot)
        create(:agent_bot_inbox, agent_bot: agent_bot, inbox: inbox)
        get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/agent_bot",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        inbox_data = JSON.parse(response.body, symbolize_names: true)
        expect(inbox_data[:agent_bot][:name]).to eq agent_bot.name
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/inboxes/:id/set_agent_bot' do
    let(:inbox) { create(:inbox, account: account) }
    let(:agent_bot) { create(:agent_bot) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/set_agent_bot"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:valid_params) { { agent_bot: agent_bot.id } }

      it 'sets the agent bot' do
        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/set_agent_bot",
             headers: admin.create_new_auth_token,
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:success)
        expect(inbox.reload.agent_bot.id).to eq agent_bot.id
      end

      it 'throw error when invalid agent bot id' do
        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/set_agent_bot",
             headers: admin.create_new_auth_token,
             params: { agent_bot: 0 },
             as: :json

        expect(response).to have_http_status(:not_found)
      end

      it 'disconnects the agent bot' do
        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/set_agent_bot",
             headers: admin.create_new_auth_token,
             params: { agent_bot: nil },
             as: :json

        expect(response).to have_http_status(:success)
        expect(inbox.reload.agent_bot).to be_falsey
      end

      it 'will not update agent bot when its an agent' do
        agent = create(:user, account: account, role: :agent)

        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/set_agent_bot",
             headers: agent.create_new_auth_token,
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/inboxes/:id/sync_templates' do
    let(:whatsapp_channel) do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    end
    let(:whatsapp_inbox) { create(:inbox, account: account, channel: whatsapp_channel) }
    let(:non_whatsapp_inbox) { create(:inbox, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/sync_templates"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated agent' do
      it 'returns unauthorized for agent' do
        post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/sync_templates",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated administrator' do
      context 'with WhatsApp inbox' do
        it 'syncs templates immediately and returns the refreshed inbox payload' do
          stub_request(:get, 'https://graph.facebook.com/v22.0/123456789/message_templates')
            .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: { data: [] }.to_json)

          post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/sync_templates",
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
          expect(response.parsed_body['id']).to eq(whatsapp_inbox.id)
        end

        it 'handles template sync errors gracefully' do
          allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates).and_raise(StandardError, 'Job failed')

          post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/sync_templates",
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:internal_server_error)
          json_response = response.parsed_body
          expect(json_response['error']).to eq('Job failed')
        end
      end

      context 'with non-WhatsApp inbox' do
        it 'returns unprocessable entity error' do
          post "/api/v1/accounts/#{account.id}/inboxes/#{non_whatsapp_inbox.id}/sync_templates",
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          json_response = response.parsed_body
          expect(json_response['error']).to eq('Template sync is only available for WhatsApp channels')
        end
      end

      context 'with non-existent inbox' do
        it 'returns not found error' do
          post "/api/v1/accounts/#{account.id}/inboxes/999999/sync_templates",
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/inboxes/{inbox.id}/health' do
    let(:whatsapp_channel) do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    end
    let(:whatsapp_inbox) { create(:inbox, account: account, channel: whatsapp_channel) }
    let(:non_whatsapp_inbox) { create(:inbox, account: account) }
    let(:health_service) { instance_double(Whatsapp::HealthService) }
    let(:health_data) do
      {
        display_phone_number: '+1234567890',
        verified_name: 'Test Business',
        name_status: 'APPROVED',
        quality_rating: 'GREEN',
        messaging_limit_tier: 'TIER_1000',
        account_mode: 'LIVE',
        business_id: 'business123'
      }
    end

    before do
      allow(Whatsapp::HealthService).to receive(:new).and_return(health_service)
      allow(health_service).to receive(:fetch_health_status).and_return(health_data)
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/health"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      context 'with WhatsApp inbox' do
        it 'returns health data for administrator' do
          get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/health",
              headers: admin.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:success)
          json_response = response.parsed_body
          expect(json_response).to include(
            'display_phone_number' => '+1234567890',
            'verified_name' => 'Test Business',
            'name_status' => 'APPROVED',
            'quality_rating' => 'GREEN',
            'messaging_limit_tier' => 'TIER_1000',
            'account_mode' => 'LIVE',
            'business_id' => 'business123'
          )
        end

        it 'returns health data for agent with inbox access' do
          create(:inbox_member, user: agent, inbox: whatsapp_inbox)

          get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/health",
              headers: agent.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:success)
          json_response = response.parsed_body
          expect(json_response['display_phone_number']).to eq('+1234567890')
        end

        it 'returns unauthorized for agent without inbox access' do
          get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/health",
              headers: agent.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:unauthorized)
        end

        it 'calls the health service with correct channel' do
          expect(Whatsapp::HealthService).to receive(:new).with(whatsapp_channel).and_return(health_service)
          expect(health_service).to receive(:fetch_health_status)

          get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/health",
              headers: admin.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:success)
        end

        it 'handles service errors gracefully' do
          allow(health_service).to receive(:fetch_health_status).and_raise(StandardError, 'API Error')

          get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/health",
              headers: admin.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:unprocessable_content)
          json_response = response.parsed_body
          expect(json_response['error']).to include('API Error')
        end
      end

      context 'with non-WhatsApp inbox' do
        it 'returns bad request error for administrator' do
          get "/api/v1/accounts/#{account.id}/inboxes/#{non_whatsapp_inbox.id}/health",
              headers: admin.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:bad_request)
          json_response = response.parsed_body
          expect(json_response['error']).to eq('Health data only available for WhatsApp Cloud API channels')
        end

        it 'returns bad request error for agent' do
          create(:inbox_member, user: agent, inbox: non_whatsapp_inbox)

          get "/api/v1/accounts/#{account.id}/inboxes/#{non_whatsapp_inbox.id}/health",
              headers: agent.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:bad_request)
          json_response = response.parsed_body
          expect(json_response['error']).to eq('Health data only available for WhatsApp Cloud API channels')
        end
      end

      context 'with WhatsApp non-cloud inbox' do
        let(:whatsapp_default_channel) do
          create(:channel_whatsapp, account: account, provider: 'default', sync_templates: false, validate_provider_config: false)
        end
        let(:whatsapp_default_inbox) { create(:inbox, account: account, channel: whatsapp_default_channel) }

        it 'returns bad request error for non-cloud provider' do
          get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_default_inbox.id}/health",
              headers: admin.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:bad_request)
          json_response = response.parsed_body
          expect(json_response['error']).to eq('Health data only available for WhatsApp Cloud API channels')
        end
      end

      context 'with non-existent inbox' do
        it 'returns not found error' do
          get "/api/v1/accounts/#{account.id}/inboxes/999999/health",
              headers: admin.create_new_auth_token,
              as: :json

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/inboxes/{inbox.id}/sync_templates' do
    let(:whatsapp_channel) do
      create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
    end
    let(:whatsapp_inbox) { whatsapp_channel.inbox }
    let(:remote_template) do
      {
        'name' => 'appointment_confirmation',
        'language' => 'en',
        'status' => 'APPROVED',
        'category' => 'UTILITY',
        'components' => [{ 'type' => 'BODY', 'text' => 'Your appointment is confirmed' }]
      }
    end

    it 'syncs templates immediately and returns the refreshed inbox payload' do
      stub_request(:get, 'https://graph.facebook.com/v22.0/123456789/message_templates')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: { data: [remote_template] }.to_json)

      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/sync_templates",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(whatsapp_inbox.id)
      expect(response.parsed_body['message_templates'].first['name']).to eq('appointment_confirmation')
      expect(response.parsed_body['message_templates'].first['status']).to eq('APPROVED')
    end
  end
end
