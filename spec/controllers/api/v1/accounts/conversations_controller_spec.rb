require 'rails_helper'

RSpec.describe 'Conversations API', type: :request do
  let(:account) { create(:account) }

  describe 'GET /api/v1/accounts/{account.id}/conversations' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/conversations"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:conversation) { create(:conversation, account: account) }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'returns all conversations with messages' do
        message = create(:message, conversation: conversation, account: account)
        get "/api/v1/accounts/#{account.id}/conversations",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:data][:meta][:all_count]).to eq(1)
        expect(body[:data][:meta].keys).to include(:all_count, :mine_count, :assigned_count, :unassigned_count)
        expect(body[:data][:payload].first[:uuid]).to eq(conversation.uuid)
        expect(body[:data][:payload].first[:messages].first[:id]).to eq(message.id)
      end

      it 'returns latest customer and reply timestamps' do
        incoming_message = create(
          :message,
          conversation: conversation,
          account: account,
          message_type: :incoming,
          created_at: Time.zone.parse('2026-01-01 10:00:00 UTC')
        )
        outgoing_message = create(
          :message,
          conversation: conversation,
          account: account,
          message_type: :outgoing,
          created_at: Time.zone.parse('2026-01-01 11:00:00 UTC')
        )
        create(
          :message,
          conversation: conversation,
          account: account,
          message_type: :incoming,
          private: true,
          created_at: Time.zone.parse('2026-01-01 12:00:00 UTC')
        )

        get "/api/v1/accounts/#{account.id}/conversations",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        payload = JSON.parse(response.body, symbolize_names: true).dig(:data, :payload).first
        expect(payload[:last_incoming_message_at]).to eq(incoming_message.created_at.to_i)
        expect(payload[:last_outgoing_message_at]).to eq(outgoing_message.created_at.to_i)
      end

      it 'returns CRM deal stage accents for linked deals' do
        account.enable_features!('crm_deals')
        pipeline = create(:crm_pipeline, account: account)
        first_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'New', color: '#22C55E', position: 1)
        second_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Qualified', color: '#3B82F6', position: 2)
        create(:crm_deal, account: account, pipeline: pipeline, stage: first_stage, originating_conversation: conversation)
        contact_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: second_stage)
        create(:crm_deal_contact, account: account, deal: contact_deal, contact: conversation.contact)

        get "/api/v1/accounts/#{account.id}/conversations",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        stages = JSON.parse(response.body, symbolize_names: true).dig(:data, :payload).first[:crm_deal_stages]
        expect(stages.pluck(:id)).to eq([first_stage.id, second_stage.id])
        expect(stages.pluck(:color)).to eq(%w[#22C55E #3B82F6])
        expect(stages.pluck(:pipeline_name)).to eq([pipeline.name, pipeline.name])
      end

      it 'returns scheduling appointment status accents for linked appointments' do
        account.enable_features!('scheduling')
        create_sidebar_appointment(conversation, status: 'confirmed')
        create_sidebar_appointment(conversation, status: 'completed')

        get "/api/v1/accounts/#{account.id}/conversations",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        statuses = JSON.parse(response.body, symbolize_names: true).dig(:data, :payload).first[:scheduling_appointment_statuses]
        expect(statuses).to eq(
          [
            { status: 'confirmed', count: 1 },
            { status: 'completed', count: 1 }
          ]
        )
      end

      it 'returns full unread counts for public incoming messages' do
        conversation.update!(agent_last_seen_at: 1.hour.ago)
        create_list(
          :message,
          12,
          conversation: conversation,
          account: account,
          message_type: :incoming,
          private: false,
          created_at: 10.minutes.ago
        )
        create(:message, conversation: conversation, account: account, message_type: :incoming, private: true, created_at: 10.minutes.ago)
        create(:message, conversation: conversation, account: account, message_type: :outgoing, created_at: 10.minutes.ago)
        create(:message, conversation: conversation, account: account, message_type: :incoming, private: false, created_at: 2.hours.ago)

        get "/api/v1/accounts/#{account.id}/conversations",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:data][:payload].first[:unread_count]).to eq(12)
      end

      it 'returns sidebar unread dialog counts scoped by agent inbox access' do
        team = create(:team, account: account, allow_auto_assign: false)
        pipeline = create(:crm_pipeline, account: account)
        stage = create(:crm_stage, account: account, pipeline: pipeline)
        conversation.update!(agent_last_seen_at: 1.hour.ago, status: :pending, team: team)
        conversation.update_labels('vip')
        create(:crm_deal, account: account, pipeline: pipeline, stage: stage, originating_conversation: conversation)
        create_sidebar_appointment(conversation, status: 'confirmed')
        create_sidebar_appointment(conversation, status: 'confirmed')
        create_list(
          :message,
          2,
          conversation: conversation,
          account: account,
          created_at: 10.minutes.ago
        )
        create(:message, conversation: conversation, account: account, private: true, created_at: 10.minutes.ago)
        create(:message, conversation: conversation, account: account, message_type: :outgoing, created_at: 10.minutes.ago)

        other_unread_conversation = create(
          :conversation,
          account: account,
          inbox: conversation.inbox,
          status: :pending,
          team: team,
          agent_last_seen_at: 1.hour.ago
        )
        other_unread_conversation.update_labels('vip')
        create_sidebar_appointment(other_unread_conversation, status: 'scheduled')
        create(:message, conversation: other_unread_conversation, account: account, created_at: 10.minutes.ago)

        inaccessible_conversation = create(:conversation, account: account, status: :open, agent_last_seen_at: 1.hour.ago)
        inaccessible_conversation.update_labels('vip')
        create_sidebar_appointment(inaccessible_conversation, status: 'confirmed')
        create(:scheduling_appointment, account: account, status: 'confirmed')
        create(:message, conversation: inaccessible_conversation, account: account, created_at: 10.minutes.ago)

        get "/api/v1/accounts/#{account.id}/conversations/sidebar_unread_counts",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:counts]).to eq(
          all: 2,
          statuses: { pending: 2 },
          inboxes: { conversation.inbox_id.to_s.to_sym => 2 },
          teams: { team.id.to_s.to_sym => 2 },
          labels: { vip: 2 },
          pipelines: { pipeline.id.to_s.to_sym => 1 },
          stages: { stage.id.to_s.to_sym => 1 },
          appointment_statuses: { any: 2, confirmed: 1, scheduled: 1 }
        )
      end

      it 'does not use private notes as conversation preview messages' do
        public_message = create(:message, conversation: conversation, account: account, content: 'Customer visible reply')
        create(
          :message,
          conversation: conversation,
          account: account,
          message_type: :outgoing,
          private: true,
          content: 'Automatic reply could not be generated. Handoff to human agent was triggered.'
        )

        get "/api/v1/accounts/#{account.id}/conversations",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        payload = body[:data][:payload].first
        expect(payload[:messages].first[:id]).to eq(public_message.id)
        expect(payload[:messages].first[:content]).to eq('Customer visible reply')
        expect(payload[:last_non_activity_message][:id]).to eq(public_message.id)
      end

      it 'returns conversations with empty messages array for conversations with out messages' do
        get "/api/v1/accounts/#{account.id}/conversations",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:data][:meta][:all_count]).to eq(1)
        expect(body[:data][:payload].first[:messages]).to eq([])
      end

      it 'returns unattended conversations' do
        attended_conversation = create(:conversation, account: account, first_reply_created_at: Time.now.utc)
        # to ensure that waiting since value is populated
        create(:message, message_type: :outgoing, conversation: attended_conversation, account: account)
        unattended_conversation_no_first_reply = create(:conversation, account: account, first_reply_created_at: nil)
        unattended_conversation_waiting_since = create(:conversation, account: account, first_reply_created_at: Time.now.utc)

        agent_1 = create(:user, account: account, role: :agent)
        create(:inbox_member, user: agent_1, inbox: attended_conversation.inbox)
        create(:inbox_member, user: agent_1, inbox: unattended_conversation_no_first_reply.inbox)
        create(:inbox_member, user: agent_1, inbox: unattended_conversation_waiting_since.inbox)

        get "/api/v1/accounts/#{account.id}/conversations",
            headers: agent_1.create_new_auth_token,
            params: { conversation_type: 'unattended' },
            as: :json

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:data][:meta][:all_count]).to eq(2)
        expect(body[:data][:payload].count).to eq(2)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/conversations/meta' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/conversations/meta"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        conversation = create(:conversation, account: account)
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'returns all conversations counts' do
        get "/api/v1/accounts/#{account.id}/conversations/meta",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body[:meta].keys).to include(:all_count, :mine_count, :assigned_count, :unassigned_count)
        expect(body[:meta][:all_count]).to eq(1)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/conversations/search' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/conversations/search", params: { q: 'test' }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        conversation = create(:conversation, account: account)
        create(:message, conversation: conversation, account: account, content: 'test1')
        create(:message, conversation: conversation, account: account, content: 'test2')
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'returns all conversations with messages containing the search query' do
        get "/api/v1/accounts/#{account.id}/conversations/search",
            headers: agent.create_new_auth_token,
            params: { q: 'test1' },
            as: :json

        expect(response).to have_http_status(:success)
        response_data = JSON.parse(response.body, symbolize_names: true)
        expect(response_data[:meta][:all_count]).to eq(1)
        expect(response_data[:payload].first[:messages].first[:content]).to eq 'test1'
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/conversations/filter' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/filter", params: { q: 'test' }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        conversation = create(:conversation, account: account)
        create(:message, conversation: conversation, account: account, content: 'test1')
        create(:message, conversation: conversation, account: account, content: 'test2')
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'returns all conversations matching the query' do
        post "/api/v1/accounts/#{account.id}/conversations/filter",
             headers: agent.create_new_auth_token,
             params: {
               payload: [{
                 attribute_key: 'status',
                 filter_operator: 'equal_to',
                 values: ['open']
               }]
             },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        response_data = JSON.parse(response.body, symbolize_names: true)
        expect(response_data.count).to eq(2)
      end

      it 'keeps unread CRM stage counts switchable when sidebar CRM context is combined with advanced filters' do
        pipeline = create(:crm_pipeline, account: account)
        matching_stage = create(:crm_stage, account: account, pipeline: pipeline)
        other_stage = create(:crm_stage, account: account, pipeline: pipeline)
        matching_conversation = create(:conversation, account: account, status: :open, agent_last_seen_at: 1.hour.ago)
        other_stage_conversation = create(:conversation, account: account, status: :open, agent_last_seen_at: 1.hour.ago)

        [matching_conversation, other_stage_conversation].each do |conversation|
          create(:inbox_member, user: agent, inbox: conversation.inbox)
          create(:message, account: account, conversation: conversation, created_at: 10.minutes.ago)
        end

        create(:crm_deal, account: account, pipeline: pipeline, stage: matching_stage, originating_conversation: matching_conversation)
        create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage, originating_conversation: other_stage_conversation)

        post "/api/v1/accounts/#{account.id}/conversations/filter?crm_stage_id=#{matching_stage.id}",
             headers: agent.create_new_auth_token,
             params: {
               payload: [{
                 attribute_key: 'status',
                 filter_operator: 'equal_to',
                 values: ['open']
               }]
             },
             as: :json

        expect(response).to have_http_status(:success)
        response_data = JSON.parse(response.body, symbolize_names: true)
        expect(response_data[:payload].pluck(:id)).to contain_exactly(matching_conversation.display_id)
        expect(response_data.dig(:meta, :unread_counts, :stages)).to include(
          matching_stage.id.to_s.to_sym => 1,
          other_stage.id.to_s.to_sym => 1
        )
      end

      it 'returns error if the filters contain invalid attributes' do
        post "/api/v1/accounts/#{account.id}/conversations/filter",
             headers: agent.create_new_auth_token,
             params: {
               payload: [{
                 attribute_key: 'phone_number',
                 filter_operator: 'equal_to',
                 values: ['open']
               }]
             },
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        response_data = JSON.parse(response.body, symbolize_names: true)
        expect(response_data[:error]).to include('Invalid attribute key - [phone_number]')
      end

      it 'returns error if the filters contain invalid operator' do
        post "/api/v1/accounts/#{account.id}/conversations/filter",
             headers: agent.create_new_auth_token,
             params: {
               payload: [{
                 attribute_key: 'status',
                 filter_operator: 'eq',
                 values: ['open']
               }]
             },
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        response_data = JSON.parse(response.body, symbolize_names: true)
        expect(response_data[:error]).to eq('Invalid operator. The allowed operators for status are [equal_to,not_equal_to].')
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/conversations/:id' do
    let(:conversation) { create(:conversation, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      it 'does not shows the conversation if you do not have access to it' do
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'shows the conversation if you are an administrator' do
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(JSON.parse(response.body, symbolize_names: true)[:id]).to eq(conversation.display_id)
      end

      it 'shows the conversation if you are an agent with access to inbox' do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:id]).to eq(conversation.display_id)
      end

      it 'returns CRM deal stage accents on the conversation detail payload' do
        account.enable_features!('crm_deals')
        create(:inbox_member, user: agent, inbox: conversation.inbox)
        pipeline = create(:crm_pipeline, account: account)
        stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#22C55E')
        create(:crm_deal, account: account, pipeline: pipeline, stage: stage, originating_conversation: conversation)

        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:crm_deal_stages]).to include(
          a_hash_including(id: stage.id, color: '#22C55E', pipeline_name: pipeline.name)
        )
      end

      it 'includes contact inbox identity metadata for conversation headers' do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
        conversation.contact_inbox.update!(source_id: 'client-source-627')
        create(:contact_channel_profile,
               contact_inbox: conversation.contact_inbox,
               username: 'client_login_627',
               identifier: 'client-id-627')

        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
            headers: agent.create_new_auth_token,
            as: :json

        body = JSON.parse(response.body, symbolize_names: true)
        expect(body.dig(:meta, :contact_inbox, :source_id)).to eq('client-source-627')
        expect(body.dig(:meta, :contact_inbox, :channel_profile, :username)).to eq('client_login_627')
        expect(body.dig(:meta, :contact_inbox, :channel_profile, :identifier)).to eq('client-id-627')
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/conversations/:id' do
    let(:conversation) { create(:conversation, account: account) }
    let(:params) { { priority: 'high' } }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        patch "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
              params: params

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      it 'does not update the conversation if you do not have access to it' do
        patch "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
              params: params,
              headers: agent.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'updates the conversation if you are an administrator' do
        patch "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
              params: params,
              headers: administrator.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(JSON.parse(response.body, symbolize_names: true)[:priority]).to eq('high')
      end

      it 'updates the conversation if you are an agent with access to inbox' do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
        patch "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
              params: params,
              headers: agent.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:priority]).to eq('high')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations' do
    let(:contact) { create(:contact, account: account) }
    let(:inbox) { create(:inbox, account: account) }
    let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations",
             params: { source_id: contact_inbox.source_id },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent, auto_offline: false) }
      let(:team) { create(:team, account: account) }

      it 'will not create a new conversation if agent does not have access to inbox' do
        allow(Rails.configuration.dispatcher).to receive(:dispatch)
        additional_attributes = { test: 'test' }
        post "/api/v1/accounts/#{account.id}/conversations",
             headers: agent.create_new_auth_token,
             params: { source_id: contact_inbox.source_id, additional_attributes: additional_attributes },
             as: :json
        expect(response).to have_http_status(:unauthorized)
      end

      it 'does not resolve a source-only contact inbox from another account' do
        foreign_account = create(:account)
        foreign_inbox = create(:inbox, account: foreign_account)
        foreign_contact = create(:contact, account: foreign_account)
        foreign_contact_inbox = create(:contact_inbox, contact: foreign_contact, inbox: foreign_inbox)

        post "/api/v1/accounts/#{account.id}/conversations",
             headers: agent.create_new_auth_token,
             params: { source_id: foreign_contact_inbox.source_id },
             as: :json

        expect(response).to have_http_status(:not_found)
      end

      context 'when it is an authenticated user who has access to the inbox' do
        before do
          create(:inbox_member, user: agent, inbox: inbox)
          create(:team_member, user: agent, team: team)
        end

        it 'creates a new conversation' do
          allow(Rails.configuration.dispatcher).to receive(:dispatch)
          additional_attributes = { test: 'test' }
          post "/api/v1/accounts/#{account.id}/conversations",
               headers: agent.create_new_auth_token,
               params: { source_id: contact_inbox.source_id, additional_attributes: additional_attributes },
               as: :json

          expect(response).to have_http_status(:success)
          expect(response).to conform_schema(200)
          response_data = JSON.parse(response.body, symbolize_names: true)
          expect(response_data[:additional_attributes]).to eq(additional_attributes)
        end

        it 'does not reuse an explicit contact inbox identity from another account' do
          foreign_account = create(:account)
          foreign_inbox = create(:inbox, account: foreign_account)
          foreign_contact = create(:contact, account: foreign_account)
          foreign_contact_inbox = create(:contact_inbox, contact: foreign_contact, inbox: foreign_inbox)

          post "/api/v1/accounts/#{account.id}/conversations",
               headers: agent.create_new_auth_token,
               params: {
                 source_id: contact_inbox.source_id,
                 contact_inbox_id: foreign_contact_inbox.id,
                 inbox_id: inbox.id,
                 contact_id: contact.id
               },
               as: :json

          expect(response).to have_http_status(:not_found)
        end

        it 'does not create a new conversation if source_id is not unique' do
          new_contact = create(:contact, account: account)

          post "/api/v1/accounts/#{account.id}/conversations",
               headers: agent.create_new_auth_token,
               params: { source_id: contact_inbox.source_id, inbox_id: inbox.id, contact_id: new_contact.id },
               as: :json
          expect(response).to have_http_status(:unprocessable_content)
        end

        it 'creates a conversation in specificed status' do
          allow(Rails.configuration.dispatcher).to receive(:dispatch)
          post "/api/v1/accounts/#{account.id}/conversations",
               headers: agent.create_new_auth_token,
               params: { source_id: contact_inbox.source_id, status: 'pending' },
               as: :json

          expect(response).to have_http_status(:success)
          response_data = JSON.parse(response.body, symbolize_names: true)
          expect(response_data[:status]).to eq('pending')
        end

        it 'creates a new conversation with message when message is passed' do
          allow(Rails.configuration.dispatcher).to receive(:dispatch)
          post "/api/v1/accounts/#{account.id}/conversations",
               headers: agent.create_new_auth_token,
               params: { source_id: contact_inbox.source_id, message: { content: 'hi' } },
               as: :json

          expect(response).to have_http_status(:success)
          response_data = JSON.parse(response.body, symbolize_names: true)
          expect(response_data[:additional_attributes]).to eq({})
          expect(account.conversations.find_by(display_id: response_data[:id]).messages.outgoing.first.content).to eq 'hi'
        end

        context 'with an official WhatsApp inbox' do
          let(:inbox) do
            create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
          end

          it 'creates a free-text conversation while another conversation keeps the reply window open' do
            previous_conversation = create(
              :conversation,
              account: account,
              inbox: inbox,
              contact: contact,
              contact_inbox: contact_inbox,
              status: :resolved
            )
            create(
              :message,
              account: account,
              inbox: inbox,
              conversation: previous_conversation,
              message_type: :incoming,
              created_at: 1.hour.ago
            )

            post "/api/v1/accounts/#{account.id}/conversations",
                 headers: agent.create_new_auth_token,
                 params: {
                   source_id: contact_inbox.source_id,
                   contact_inbox_id: contact_inbox.id,
                   inbox_id: inbox.id,
                   contact_id: contact.id,
                   message: { content: 'reply inside the active window' }
                 },
                 as: :json

            expect(response).to have_http_status(:success)
            created_conversation = account.conversations.find_by(display_id: response.parsed_body['id'])
            expect(created_conversation.messages.outgoing.first.content).to eq('reply inside the active window')
          end

          it 'rejects free text and rolls back the conversation outside the reply window' do
            expect do
              post "/api/v1/accounts/#{account.id}/conversations",
                   headers: agent.create_new_auth_token,
                   params: {
                     source_id: contact_inbox.source_id,
                     inbox_id: inbox.id,
                     contact_id: contact.id,
                     message: { content: 'reply outside the active window' }
                   },
                   as: :json
            end.not_to change(account.conversations, :count)

            expect(response).to have_http_status(:unprocessable_content)
            expect(response.parsed_body['error']).to include('approved channel_template')
          end
        end

        it 'calls contact inbox builder if contact_id and inbox_id is present' do
          builder = double
          allow(Rails.configuration.dispatcher).to receive(:dispatch)
          allow(ContactInboxBuilder).to receive(:new).with(contact: contact, inbox: inbox, source_id: nil, hmac_verified: false).and_return(builder)
          allow(builder).to receive(:perform)
          expect(builder).to receive(:perform)

          post "/api/v1/accounts/#{account.id}/conversations",
               headers: agent.create_new_auth_token,
               params: { contact_id: contact.id, inbox_id: inbox.id, hmac_verified: 'false' },
               as: :json
        end

        it 'creates a new conversation with assignee and team' do
          allow(Rails.configuration.dispatcher).to receive(:dispatch)
          post "/api/v1/accounts/#{account.id}/conversations",
               headers: agent.create_new_auth_token,
               params: { source_id: contact_inbox.source_id, contact_id: contact.id, inbox_id: inbox.id, assignee_id: agent.id, team_id: team.id },
               as: :json

          expect(response).to have_http_status(:success)
          response_data = JSON.parse(response.body, symbolize_names: true)
          expect(response_data[:meta][:assignee][:name]).to eq(agent.name)
          expect(response_data[:meta][:team][:name]).to eq(team.name)
        end

        it 'does not create a conversation when the account conversation limit is reached' do
          account.update!(limits: { conversations: 1 })
          create(:conversation, account: account)

          post "/api/v1/accounts/#{account.id}/conversations",
               headers: agent.create_new_auth_token,
               params: { source_id: contact_inbox.source_id, additional_attributes: { test: 'test' } },
               as: :json

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body['message']).to include('Account conversation limit exceeded')
        end
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/toggle_status' do
    let(:conversation) { create(:conversation, account: account) }
    let(:inbox) { create(:inbox, account: account) }
    let(:pending_conversation) { create(:conversation, inbox: inbox, account: account, status: 'pending') }
    let(:agent_bot) { create(:agent_bot, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_status"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'toggles the conversation status if status is empty' do
        expect(conversation.status).to eq('open')

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_status",
             headers: agent.create_new_auth_token,
             params: { status: '' },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('resolved')
      end

      it 'toggles the conversation status to open from pending' do
        conversation.update!(status: 'pending')

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_status",
             headers: agent.create_new_auth_token,
             params: { status: 'open' },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response).to conform_schema(200)
        expect(conversation.reload.status).to eq('open')
      end

      it 'self assign if agent changes the conversation status to open' do
        conversation.update!(status: 'pending')
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_status",
             headers: agent.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('open')
        expect(conversation.reload.assignee_id).to eq(agent.id)
      end

      it 'disbale self assign if admin changes the conversation status to open' do
        conversation.update!(status: 'pending')
        conversation.update!(assignee_id: nil)
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_status",
             headers: administrator.create_new_auth_token,
             as: :json
        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('open')
        expect(conversation.reload.assignee_id).not_to eq(administrator.id)
      end

      it 'toggles the conversation status to specific status when parameter is passed' do
        expect(conversation.status).to eq('open')

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_status",
             headers: agent.create_new_auth_token,
             params: { status: 'pending' },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('pending')
      end

      it 'toggles the conversation status to snoozed when parameter is passed' do
        expect(conversation.status).to eq('open')
        snoozed_until = (DateTime.now.utc + 2.days).to_i
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_status",
             headers: agent.create_new_auth_token,
             params: { status: 'snoozed', snoozed_until: snoozed_until },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('snoozed')
        expect(conversation.reload.snoozed_until.to_i).to eq(snoozed_until)
      end
    end

    context 'when it is an authenticated bot' do
      # this test will basically ensure that the status actually changes
      # regardless of the value to be done
      it 'returns authorized for arbritrary status' do
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)

        conversation.update!(status: 'open')
        expect(conversation.reload.status).to eq('open')
        snoozed_until = (DateTime.now.utc + 2.days).to_i

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_status",
             headers: { api_access_token: agent_bot.access_token.token },
             params: { status: 'snoozed', snoozed_until: snoozed_until },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('snoozed')
      end

      it 'triggers handoff event when moving from pending to open' do
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)
        allow(Rails.configuration.dispatcher).to receive(:dispatch)

        post "/api/v1/accounts/#{account.id}/conversations/#{pending_conversation.display_id}/toggle_status",
             headers: { api_access_token: agent_bot.access_token.token },
             params: { status: 'open' },
             as: :json

        expect(response).to have_http_status(:success)
        expect(pending_conversation.reload.status).to eq('open')
        expect(Rails.configuration.dispatcher).to have_received(:dispatch)
          .with(Events::Types::CONVERSATION_BOT_HANDOFF, kind_of(Time), conversation: pending_conversation, notifiable_assignee_change: false,
                                                                        changed_attributes: anything, performed_by: anything)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/toggle_priority' do
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:pending_conversation) { create(:conversation, inbox: inbox, account: account, status: 'pending') }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:agent_bot) { create(:agent_bot, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_priority"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:administrator) { create(:user, account: account, role: :administrator) }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'toggles the conversation priority to nil if no value is passed' do
        expect(conversation.priority).to be_nil

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_priority",
             headers: agent.create_new_auth_token,
             params: { priority: 'low' },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.priority).to eq('low')
      end

      it 'toggles the conversation priority' do
        conversation.priority = 'low'
        conversation.save!
        expect(conversation.reload.priority).to eq('low')

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_priority",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.priority).to be_nil
      end
    end

    context 'when it is an authenticated bot' do
      it 'toggle the priority of the bot agent conversation' do
        create(:agent_bot_inbox, inbox: inbox, agent_bot: agent_bot)

        conversation.update!(priority: 'low')
        expect(conversation.reload.priority).to eq('low')

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_priority",
             headers: { api_access_token: agent_bot.access_token.token },
             params: { priority: 'high' },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.priority).to eq('high')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/toggle_typing_status' do
    let(:conversation) { create(:conversation, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_typing_status"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'toggles the conversation status' do
        allow(Rails.configuration.dispatcher).to receive(:dispatch)
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_typing_status",
             headers: agent.create_new_auth_token,
             params: { typing_status: 'on', is_private: false },
             as: :json

        expect(response).to have_http_status(:success)
        expect(Rails.configuration.dispatcher).to have_received(:dispatch)
          .with(Conversation::CONVERSATION_TYPING_ON, kind_of(Time), { conversation: conversation, user: agent, is_private: false })
      end

      it 'toggles the conversation status for private notes' do
        allow(Rails.configuration.dispatcher).to receive(:dispatch)
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_typing_status",
             headers: agent.create_new_auth_token,
             params: { typing_status: 'on', is_private: true },
             as: :json

        expect(response).to have_http_status(:success)
        expect(Rails.configuration.dispatcher).to have_received(:dispatch)
          .with(Conversation::CONVERSATION_TYPING_ON, kind_of(Time), { conversation: conversation, user: agent, is_private: true })
      end
    end

    context 'when it is an authenticated bot' do
      let(:agent_bot) { create(:agent_bot, account: account) }

      it 'toggles the conversation typing status' do
        create(:agent_bot_inbox, inbox: conversation.inbox, agent_bot: agent_bot)
        allow(Rails.configuration.dispatcher).to receive(:dispatch)

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_typing_status",
             headers: { api_access_token: agent_bot.access_token.token },
             params: { typing_status: 'on', is_private: false },
             as: :json

        expect(response).to have_http_status(:success)
        expect(Rails.configuration.dispatcher).to have_received(:dispatch)
          .with(Conversation::CONVERSATION_TYPING_ON, kind_of(Time), { conversation: conversation, user: agent_bot, is_private: false })
      end
    end

    context 'when it is an authenticated platform app token' do
      let(:platform_app) { create(:platform_app) }

      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/toggle_typing_status",
             headers: { api_access_token: platform_app.access_token.token },
             params: { typing_status: 'on', is_private: false },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/cancel_captain_response' do
    let(:conversation) { create(:conversation, account: account, status: :pending) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:cancellation_key) do
      format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: conversation.id)
    end

    before do
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      create(:captain_inbox, captain_assistant: assistant, inbox: conversation.inbox)
      create(:message, conversation: conversation, content: 'Hello', message_type: :incoming)
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    end

    after do
      Redis::Alfred.delete(cancellation_key)
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/cancel_captain_response"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'stores a cancellation token and turns off the Captain typing indicator' do
      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/cancel_captain_response",
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      cancellation_state = JSON.parse(Redis::Alfred.get(cancellation_key))
      expect(cancellation_state).to include(
        'assistant_id' => assistant.id,
        'last_message_id' => conversation.messages.incoming.last.id,
        'cancelled_by_id' => agent.id
      )
      expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_off).with(
        conversation: conversation,
        assistant: assistant
      )
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/update_last_seen' do
    let(:conversation) { create(:conversation, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'updates last seen' do
        conversation.update!(agent_last_seen_at: nil)

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.agent_last_seen_at).not_to be_nil
      end

      it 'refreshes the communication thread unread count' do
        account.enable_features!('communication_threads')
        conversation.update!(agent_last_seen_at: 1.day.ago)
        create(
          :message,
          conversation: conversation,
          account: account,
          inbox: conversation.inbox,
          message_type: :incoming,
          created_at: 1.minute.ago
        )
        communication_thread = conversation.reload.refresh_communication_thread!

        expect(communication_thread.reload.unread_count).to eq(1)

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.unread_incoming_messages_count).to eq(0)
        expect(communication_thread.reload.unread_count).to eq(0)
      end

      it 'returns the updated conversation payload' do
        conversation.update!(agent_last_seen_at: nil)

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['id']).to eq(conversation.display_id)
        expect(response.parsed_body['agent_last_seen_at']).to eq(conversation.reload.agent_last_seen_at.to_i)
        expect(response.parsed_body['unread_count']).to eq(conversation.unread_incoming_messages.count)
      end

      it 'updates assignee last seen' do
        conversation.update!(assignee_id: agent.id, agent_last_seen_at: nil)

        expect(conversation.reload.assignee_last_seen_at).to be_nil

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.assignee_last_seen_at).not_to be_nil
      end

      it 'marks unread notifications as read when updating last seen' do
        allow(Rails.configuration.dispatcher).to receive(:dispatch)
        notification = create(:notification, account: account, user: agent, primary_actor: conversation, read_at: nil)

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(notification.reload.read_at).to be_present
        expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
          'notification.updated',
          kind_of(Time),
          hash_including(notification: have_attributes(id: notification.id))
        )
      end

      it 'throttles updates within an hour when there are no unread messages' do
        conversation.update!(agent_last_seen_at: 30.minutes.ago)
        # Ensure all messages are older than agent_last_seen_at (no unread messages)
        # rubocop:disable Rails/SkipsModelValidations
        conversation.messages.update_all(created_at: 1.hour.ago)
        # rubocop:enable Rails/SkipsModelValidations
        initial_last_seen = conversation.agent_last_seen_at

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.agent_last_seen_at).to be_within(1.second).of(initial_last_seen)
      end

      it 'updates even within an hour when there are unread messages' do
        conversation.update!(agent_last_seen_at: 30.minutes.ago)
        # Create a new message after agent_last_seen_at (unread message)
        create(:message, conversation: conversation, created_at: 5.minutes.ago)
        initial_last_seen = conversation.agent_last_seen_at

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.agent_last_seen_at).not_to be_within(1.second).of(initial_last_seen)
        expect(conversation.reload.agent_last_seen_at).to be > initial_last_seen
      end

      it 'updates both if one timestamp is old even when the other is recent' do
        conversation.update!(assignee_id: agent.id, agent_last_seen_at: 2.hours.ago, assignee_last_seen_at: 30.minutes.ago)
        # Ensure all messages are older than assignee_last_seen_at (no unread messages)
        # rubocop:disable Rails/SkipsModelValidations
        conversation.messages.update_all(created_at: 1.hour.ago)
        # rubocop:enable Rails/SkipsModelValidations

        initial_agent_last_seen = conversation.agent_last_seen_at

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        # Both should be updated because agent_last_seen_at is old
        expect(conversation.reload.agent_last_seen_at).to be > initial_agent_last_seen
        expect(conversation.reload.assignee_last_seen_at).to be > initial_agent_last_seen
      end

      it 'throttles only when both timestamps are recent and no unread messages' do
        conversation.update!(assignee_id: agent.id, agent_last_seen_at: 30.minutes.ago, assignee_last_seen_at: 30.minutes.ago)
        # Ensure all messages are older (no unread messages)
        # rubocop:disable Rails/SkipsModelValidations
        conversation.messages.update_all(created_at: 1.hour.ago)
        # rubocop:enable Rails/SkipsModelValidations

        initial_agent_last_seen = conversation.agent_last_seen_at
        initial_assignee_last_seen = conversation.assignee_last_seen_at

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        # Both should remain unchanged (throttled)
        expect(conversation.reload.agent_last_seen_at).to be_within(1.second).of(initial_agent_last_seen)
        expect(conversation.reload.assignee_last_seen_at).to be_within(1.second).of(initial_assignee_last_seen)
      end

      context 'when the conversation belongs to a WhatsApp Web inbox' do
        around do |example|
          with_modified_env(
            'EVOLUTION_API_URL' => 'https://evolution.example.com',
            'EVOLUTION_API_KEY' => 'test-api-key',
            'FRONTEND_URL' => 'https://app.example.com'
          ) do
            example.run
          end
        end

        let(:channel) { create(:channel_whatsapp_web, account: account) }
        let(:contact) do
          create(
            :contact,
            account: account,
            additional_attributes: {
              canonical_jid: '15551234567@s.whatsapp.net'
            }
          )
        end
        let(:contact_inbox) do
          create(
            :contact_inbox,
            contact: contact,
            inbox: channel.inbox,
            source_id: '15551234567'
          )
        end
        let(:conversation) do
          create(
            :conversation,
            account: account,
            inbox: channel.inbox,
            contact: contact,
            contact_inbox: contact_inbox,
            agent_last_seen_at: 30.minutes.ago
          )
        end
        let!(:incoming_message) do
          create(
            :message,
            account: account,
            inbox: channel.inbox,
            conversation: conversation,
            sender: contact,
            message_type: :incoming,
            source_id: 'wa-incoming-1',
            created_at: 5.minutes.ago
          )
        end

        it 'syncs unread incoming messages back to the provider when marked read' do
          sync_service = instance_double(
            WhatsappWeb::MarkMessagesReadService,
            perform: true
          )

          expect(WhatsappWeb::MarkMessagesReadService).to receive(:new).with(
            conversation: conversation,
            messages: array_including(incoming_message)
          ).and_return(sync_service)
          expect(sync_service).to receive(:perform)

          post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
        end
      end

      context 'when the conversation belongs to a Telegram business inbox' do
        let(:channel) { create(:channel_telegram, account: account) }
        let(:contact) { create(:contact, account: account) }
        let(:contact_inbox) do
          create(
            :contact_inbox,
            contact: contact,
            inbox: channel.inbox,
            source_id: '123'
          )
        end
        let(:conversation) do
          create(
            :conversation,
            account: account,
            inbox: channel.inbox,
            contact: contact,
            contact_inbox: contact_inbox,
            additional_attributes: {
              chat_id: '123',
              business_connection_id: 'biz-1'
            },
            agent_last_seen_at: 30.minutes.ago
          )
        end
        let!(:incoming_message) do
          create(
            :message,
            account: account,
            inbox: channel.inbox,
            conversation: conversation,
            sender: contact,
            message_type: :incoming,
            source_id: '55',
            created_at: 5.minutes.ago
          )
        end

        it 'syncs unread incoming messages back to telegram when marked read' do
          sync_service = instance_double(
            Telegram::MarkMessagesReadService,
            perform: true
          )

          expect(Telegram::MarkMessagesReadService).to receive(:new).with(
            conversation: conversation,
            messages: array_including(incoming_message)
          ).and_return(sync_service)
          expect(sync_service).to receive(:perform)

          post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/update_last_seen",
               headers: agent.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
        end
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/unread' do
    let(:conversation) { create(:conversation, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/unread"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
        create(:message, conversation: conversation, account: account, inbox: conversation.inbox, content: 'Hello', message_type: 'incoming')
      end

      it 'updates last seen' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/unread",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        last_seen_at = conversation.messages.incoming.last.created_at - 1.second
        expect(conversation.reload.agent_last_seen_at).to eq(last_seen_at)
        expect(conversation.reload.assignee_last_seen_at).to eq(last_seen_at)
      end

      it 'refreshes the communication thread unread count' do
        account.enable_features!('communication_threads')
        conversation.update!(agent_last_seen_at: Time.current, assignee_last_seen_at: Time.current)
        communication_thread = conversation.reload.refresh_communication_thread!

        expect(communication_thread.reload.unread_count).to eq(0)

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/unread",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.unread_incoming_messages_count).to eq(1)
        expect(communication_thread.reload.unread_count).to eq(1)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/mute' do
    let(:conversation) { create(:conversation, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mute"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'mutes conversation' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/mute",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.resolved?).to be(true)
        expect(conversation.reload.muted?).to be(true)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/unmute' do
    let(:conversation) { create(:conversation, account: account).tap(&:mute!) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/unmute"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'unmutes conversation' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/unmute",
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.muted?).to be(false)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/transcript' do
    let(:conversation) { create(:conversation, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/transcript"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:params) { { email: 'test@test.com' } }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'mutes conversation' do
        mailer = double
        allow(ConversationReplyMailer).to receive(:with).and_return(mailer)
        allow(mailer).to receive(:conversation_transcript)
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/transcript",
             headers: agent.create_new_auth_token,
             params: params,
             as: :json

        expect(response).to have_http_status(:success)
        expect(mailer).to have_received(:conversation_transcript).with(conversation, 'test@test.com')
      end

      it 'renders error when parameter missing' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/transcript",
             headers: agent.create_new_auth_token,
             params: {},
             as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/custom_attributes' do
    let(:conversation) { create(:conversation, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/custom_attributes"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:custom_attributes) { { user_id: 1001, created_date: '23/12/2012', subscription_id: 12 } }
      let(:valid_params) { { custom_attributes: custom_attributes } }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'updates custom attributes' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/custom_attributes",
             headers: agent.create_new_auth_token,
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.custom_attributes).not_to be_nil
        expect(conversation.reload.custom_attributes.count).to eq 3
      end

      it 'merges incoming custom attributes with existing values' do
        conversation.update!(custom_attributes: { existing_key: 'existing value' })

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/custom_attributes",
             headers: agent.create_new_auth_token,
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['custom_attributes']).to eq(
          {
            'existing_key' => 'existing value',
            'user_id' => 1001,
            'created_date' => '23/12/2012',
            'subscription_id' => 12
          }
        )
        expect(conversation.reload.custom_attributes).to eq(response.parsed_body['custom_attributes'])
      end

      it 'initializes custom attributes when persisted value is nil' do
        conversation.update_columns(custom_attributes: nil)

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/custom_attributes",
             headers: agent.create_new_auth_token,
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.custom_attributes).to eq(
          {
            'user_id' => 1001,
            'created_date' => '23/12/2012',
            'subscription_id' => 12
          }
        )
      end

      it 'clears all custom attributes when an explicit empty object is provided' do
        conversation.update!(custom_attributes: { existing_key: 'existing value' })

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/custom_attributes",
             headers: agent.create_new_auth_token,
             params: { custom_attributes: {} },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['custom_attributes']).to eq({})
        expect(conversation.reload.custom_attributes).to eq({})
      end
    end

    context 'when it is a bot' do
      let(:agent_bot) { create(:agent_bot, account: account) }
      let(:custom_attributes) { { bot_id: 1001, flow_name: 'support_flow', step: 'greeting' } }
      let(:valid_params) { { custom_attributes: custom_attributes } }

      before do
        create(:agent_bot_inbox, agent_bot: agent_bot, inbox: conversation.inbox)
      end

      it 'updates custom attributes' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/custom_attributes",
             headers: { api_access_token: agent_bot.access_token.token },
             params: valid_params,
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.custom_attributes).not_to be_nil
        expect(conversation.reload.custom_attributes.count).to eq 3
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/conversations/:id/destroy_custom_attributes' do
    let(:conversation) do
      create(
        :conversation,
        account: account,
        custom_attributes: { removable_key: 'remove me', retained_key: 'keep me' }
      )
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }

      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'destroys only the requested custom attributes' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/destroy_custom_attributes",
             headers: agent.create_new_auth_token,
             params: { custom_attributes: ['removable_key'] },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['custom_attributes']).to eq({ 'retained_key' => 'keep me' })
        expect(conversation.reload.custom_attributes).to eq({ 'retained_key' => 'keep me' })
      end

      it 'treats nil custom attributes as an empty hash during deletion' do
        conversation.update_columns(custom_attributes: nil)

        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/destroy_custom_attributes",
             headers: agent.create_new_auth_token,
             params: { custom_attributes: ['removable_key'] },
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['custom_attributes']).to eq({})
        expect(conversation.reload.custom_attributes).to eq({})
      end
    end

    context 'when it is a bot' do
      let(:agent_bot) { create(:agent_bot, account: account) }

      before do
        create(:agent_bot_inbox, agent_bot: agent_bot, inbox: conversation.inbox)
      end

      it 'destroys custom attributes' do
        post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/destroy_custom_attributes",
             headers: { api_access_token: agent_bot.access_token.token },
             params: { custom_attributes: ['removable_key'] },
             as: :json

        expect(response).to have_http_status(:success)
        expect(conversation.reload.custom_attributes).to eq({ 'retained_key' => 'keep me' })
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/conversations/:id/attachments' do
    let(:conversation) { create(:conversation, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/attachments"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      before do
        create(:message, :with_attachment, conversation: conversation, account: account, inbox: conversation.inbox, message_type: 'incoming')
      end

      it 'does not return the attachments if you do not have access to it' do
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/attachments",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'return the attachments if you are an administrator' do
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/attachments",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload'].first['file_type']).to eq('image')
        expect(response_body['payload'].first['sender']['id']).to eq(conversation.messages.last.sender.id)
      end

      it 'returns the current channel profile in sender metadata' do
        create(
          :contact_channel_profile,
          contact_inbox: conversation.contact_inbox,
          display_name: 'Telegram Contact',
          avatar_url: 'https://chatwoot-assets.local/telegram.png'
        )

        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/attachments",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload'].first['sender']).to include(
          'name' => 'Telegram Contact',
          'thumbnail' => 'https://chatwoot-assets.local/telegram.png'
        )
      end

      it 'return the attachments if you are an agent with access to inbox' do
        get "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/attachments",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        response_body = response.parsed_body
        expect(response_body['payload'].length).to eq(1)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/conversations/:id' do
    let(:conversation) { create(:conversation, account: account) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:administrator) { create(:user, account: account, role: :administrator) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated agent' do
      before do
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unauthorized)
        response_body = response.parsed_body
        expect(response_body['error']).to eq('You are not authorized to do this action')
      end
    end

    context 'when it is an authenticated administrator' do
      before do
        create(:inbox_member, user: administrator, inbox: conversation.inbox)
      end

      it 'successfully deletes the conversation' do
        expect do
          delete "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}",
                 headers: administrator.create_new_auth_token,
                 as: :json
        end.to have_enqueued_job(DeleteObjectJob).with(conversation, administrator, anything)

        expect(response).to have_http_status(:ok)
      end

      it 'can delete conversations from inboxes without direct access' do
        other_inbox = create(:inbox, account: account)
        other_conversation = create(:conversation, account: account, inbox: other_inbox)

        expect do
          delete "/api/v1/accounts/#{account.id}/conversations/#{other_conversation.display_id}",
                 headers: administrator.create_new_auth_token,
                 as: :json
        end.to have_enqueued_job(DeleteObjectJob).with(other_conversation, administrator, anything)

        expect(response).to have_http_status(:ok)
      end
    end
  end

  def create_sidebar_appointment(conversation, status:)
    create(
      :scheduling_appointment,
      account: conversation.account,
      contact: conversation.contact,
      conversation: conversation,
      status: status
    )
  end
end
