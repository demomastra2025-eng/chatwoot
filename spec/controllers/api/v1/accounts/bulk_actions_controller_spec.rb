require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::BulkActionsController', type: :request do
  include ActiveJob::TestHelper
  let(:account) { create(:account) }
  let(:agent_1) { create(:user, account: account, role: :agent) }
  let(:agent_2) { create(:user, account: account, role: :agent) }
  let(:team_1) { create(:team, account: account) }

  before do
    create(:conversation, account_id: account.id, status: :open, team_id: team_1.id)
    create(:conversation, account_id: account.id, status: :open, team_id: team_1.id)
    create(:conversation, account_id: account.id, status: :open)
    create(:conversation, account_id: account.id, status: :open)
    Conversation.all.find_each do |conversation|
      create(:inbox_member, inbox: conversation.inbox, user: agent_1)
      create(:inbox_member, inbox: conversation.inbox, user: agent_2)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/bulk_action' do
    context 'when it is an unauthenticated user' do
      let!(:agent) { create(:user) }

      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/bulk_actions",
             headers: agent.create_new_auth_token,
             params: { type: 'Conversation', fields: { status: 'open' }, ids: [1, 2, 3] }

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let!(:agent) { create(:user, account: account, role: :agent) }

      before do
        Conversation.all.find_each do |conversation|
          create(:inbox_member, inbox: conversation.inbox, user: agent)
        end
      end

      it 'Ignores bulk_actions for wrong type' do
        post "/api/v1/accounts/#{account.id}/bulk_actions",
             headers: agent.create_new_auth_token,
             params: { type: 'Test', fields: { status: 'snoozed' }, ids: %w[1 2 3] }

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'Bulk update conversation status' do
        expect(Conversation.first.status).to eq('open')
        expect(Conversation.last.status).to eq('open')
        expect(Conversation.first.assignee_id).to be_nil

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: { type: 'Conversation', fields: { status: 'snoozed' }, ids: Conversation.first(3).pluck(:display_id) }

          expect(response).to have_http_status(:success)
          expect(response.parsed_body.dig('payload', 'action_name')).to eq('update_status')
        end

        expect(Conversation.first.status).to eq('snoozed')
        expect(Conversation.last.status).to eq('open')
        expect(Conversation.first.assignee_id).to be_nil
      end

      it 'accepts communication thread bulk actions' do
        contact = create(:contact, account: account)
        thread = create(:communication_thread, account: account, contact: contact)
        conversation = create(:conversation, account: account, contact: contact)
        CommunicationThreadConversation.where(account_id: account.id, conversation_id: conversation.id).delete_all
        conversation.association(:communication_thread_conversation).reset
        conversation.association(:communication_thread).reset
        account.enable_features!('communication_threads')
        create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
        create(:inbox_member, inbox: conversation.inbox, user: agent)

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions/v2",
               headers: agent.create_new_auth_token,
               params: {
                 type: 'CommunicationThread',
                 fields: { status: 'resolved' },
                 selection: {
                   mode: 'all_matching',
                   filters: { status: 'all', assignee_type: 'all' },
                   excluded_ids: []
                 }
               }
        end

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('payload', 'resource_type')).to eq('CommunicationThread')
        expect(response.parsed_body.dig('payload', 'action_name')).to eq('update_status')
        expect(response.parsed_body.dig('payload', 'metadata', 'selection_mode')).to eq('all_matching')
        expect(conversation.reload.status).to eq('resolved')
      end

      it 'rejects an empty explicit selection instead of enqueuing a successful no-op' do
        auth_headers = agent.create_new_auth_token
        clear_enqueued_jobs

        expect do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: auth_headers,
               params: { type: 'Conversation', fields: { status: 'resolved' }, ids: [] }
        end.not_to have_enqueued_job(BulkActionsJob)

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects incomplete, unknown, or invalid server selections' do
        auth_headers = agent.create_new_auth_token
        account.enable_features!('communication_threads')
        custom_attribute = create(
          :custom_attribute_definition,
          account: account,
          attribute_key: 'bulk_score',
          attribute_display_type: :number,
          attribute_model: :conversation_attribute
        )

        [
          { filters: { status: 'all' } },
          { filters: { status: 'all', assignee_type: 'all', unsupported_scope: 'ignored' } },
          { filters: { status: 'not-a-status', assignee_type: 'all' } },
          { filters: { status: 'all', assignee_type: 'everybody' } },
          { filters: { status: 'all', assignee_type: 'all', labels_scope: 'typo' } },
          { filters: { status: 'all', assignee_type: 'all', team_scope: 'typo' } },
          { filters: { status: 'all', assignee_type: 'all', unread: 'sometimes' } },
          { filters: { status: 'all', assignee_type: 'all', unread: 'true' } },
          { filters: { status: 'all', assignee_type: 'all', team_id: 'not-an-id' } },
          { filters: { status: 'all', assignee_type: 'all', page: '' } },
          { filters: { status: 'all', assignee_type: 'all', labels: {} } },
          { filters: { status: 'all', assignee_type: 'all', labels: '' } },
          { filters: { status: 'all', assignee_type: 'all', communication_thread_mode: false } },
          { filters: { status: 'all', assignee_type: 'all', communication_thread_mode: 'true' } },
          { filters: { status: 'all', assignee_type: 'all', conversation_type: 'unknown' } },
          { filters: { status: 'all', assignee_type: 'all', appointment_status: '' } },
          { filters: { status: 'all', assignee_type: 'all' }, excluded_ids: '1' },
          { filters: { status: 'all', assignee_type: 'all' }, excluded_ids: ['not-an-id'] },
          { filters: { status: 'all', assignee_type: 'all' }, payload: {} },
          { filters: { status: 'all', assignee_type: 'all' }, payload: '' },
          {
            filters: { status: 'all', assignee_type: 'all' },
            payload: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], unexpected: true }]
          },
          {
            filters: { status: 'all', assignee_type: 'all' },
            payload: [{ attribute_key: 'status', filter_operator: 'unknown', values: ['open'] }]
          },
          {
            filters: { status: 'all', assignee_type: 'all' },
            payload: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['unknown'] }]
          },
          {
            filters: { status: 'all', assignee_type: 'all' },
            payload: [
              {
                attribute_key: custom_attribute.attribute_key,
                custom_attribute_type: 'conversation_attribute',
                filter_operator: 'contains',
                values: ['80']
              }
            ]
          },
          {
            filters: { status: 'all', assignee_type: 'all' },
            payload: [
              {
                attribute_key: custom_attribute.attribute_key,
                custom_attribute_type: 'invalid',
                filter_operator: 'contains',
                values: ['80']
              }
            ]
          },
          {
            filters: { status: 'all', assignee_type: 'all' },
            payload: [
              {
                attribute_key: custom_attribute.attribute_key,
                custom_attribute_type: 'contact_attribute',
                filter_operator: 'contains',
                values: ['80']
              }
            ]
          },
          {
            filters: { status: 'all', assignee_type: 'all' },
            payload: [
              { attribute_key: 'status', filter_operator: 'equal_to', values: ['open'] },
              { attribute_key: 'priority', filter_operator: 'equal_to', values: ['high'] }
            ]
          }
        ].each do |selection|
          clear_enqueued_jobs
          post "/api/v1/accounts/#{account.id}/bulk_actions/v2",
               headers: auth_headers,
               params: {
                 type: 'CommunicationThread',
                 fields: { status: 'resolved' },
                 selection: { mode: 'all_matching', **selection }
               },
               as: :json

          bulk_jobs = enqueued_jobs.select { |job| job[:job] == BulkActionsJob }
          expect(bulk_jobs).to be_empty, "accepted invalid selection: #{selection.inspect}"

          expect(response).to have_http_status(:unprocessable_content)
        end
      end

      it 'returns the bulk action run status for the current user' do
        auth_headers = agent.create_new_auth_token

        post "/api/v1/accounts/#{account.id}/bulk_actions",
             headers: auth_headers,
             params: { type: 'Conversation', fields: { status: 'snoozed' }, ids: Conversation.first(2).pluck(:display_id) }

        expect(response).to have_http_status(:success)

        run_id = response.parsed_body.dig('payload', 'id')

        get "/api/v1/accounts/#{account.id}/bulk_action_runs/#{run_id}",
            headers: auth_headers

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('payload', 'resource_type')).to eq('Conversation')
      end

      it 'Bulk update conversation team id to none' do
        params = { type: 'Conversation', fields: { team_id: 0 }, ids: Conversation.first(1).pluck(:display_id) }
        expect(Conversation.first.team).not_to be_nil

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: params

          expect(response).to have_http_status(:success)
        end

        expect(Conversation.first.team).to be_nil

        last_activity_message = Conversation.first.messages.activity.last

        expect(last_activity_message.content).to eq("Unassigned from #{team_1.name} by #{agent.name}")
      end

      it 'Bulk update conversation team id to team' do
        params = { type: 'Conversation', fields: { team_id: team_1.id }, ids: Conversation.last(2).pluck(:display_id) }
        expect(Conversation.last.team_id).to be_nil

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: params

          expect(response).to have_http_status(:success)
        end

        expect(Conversation.last.team).to eq(team_1)

        last_activity_message = Conversation.last.messages.activity.last

        expect(last_activity_message.content).to eq("Assigned to #{team_1.name} by #{agent.name}")
      end

      it 'Bulk update conversation assignee id' do
        params = { type: 'Conversation', fields: { assignee_id: agent_1.id }, ids: Conversation.first(3).pluck(:display_id) }

        expect(Conversation.first.status).to eq('open')
        expect(Conversation.first.assignee_id).to be_nil
        expect(Conversation.second.assignee_id).to be_nil

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: params

          expect(response).to have_http_status(:success)
          expect(response.parsed_body.dig('payload', 'action_name')).to eq('assign_agent')
        end

        expect(Conversation.first.assignee_id).to eq(agent_1.id)
        expect(Conversation.second.assignee_id).to eq(agent_1.id)
        expect(Conversation.first.status).to eq('open')
      end

      it 'Bulk remove assignee id from conversations' do
        Conversation.first.update(assignee_id: agent_1.id)
        Conversation.second.update(assignee_id: agent_2.id)
        params = { type: 'Conversation', fields: { assignee_id: nil }, ids: Conversation.first(3).pluck(:display_id) }

        expect(Conversation.first.status).to eq('open')
        expect(Conversation.first.assignee_id).to eq(agent_1.id)
        expect(Conversation.second.assignee_id).to eq(agent_2.id)

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: params

          expect(response).to have_http_status(:success)
          expect(response.parsed_body.dig('payload', 'action_name')).to eq('assign_agent')
        end

        expect(Conversation.first.assignee_id).to be_nil
        expect(Conversation.second.assignee_id).to be_nil
        expect(Conversation.first.status).to eq('open')
      end

      it 'Do not bulk update status to nil' do
        Conversation.first.update(assignee_id: agent_1.id)
        Conversation.second.update(assignee_id: agent_2.id)
        params = { type: 'Conversation', fields: { status: nil }, ids: Conversation.first(3).pluck(:display_id) }

        expect(Conversation.first.status).to eq('open')

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: params

          expect(response).to have_http_status(:success)
        end

        expect(Conversation.first.status).to eq('open')
      end

      it 'Bulk update conversation status and assignee id' do
        params = { type: 'Conversation', fields: { assignee_id: agent_1.id, status: 'snoozed' }, ids: Conversation.first(3).pluck(:display_id) }

        expect(Conversation.first.status).to eq('open')
        expect(Conversation.second.assignee_id).to be_nil

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: params

          expect(response).to have_http_status(:success)
        end

        expect(Conversation.first.assignee_id).to eq(agent_1.id)
        expect(Conversation.second.assignee_id).to eq(agent_1.id)
        expect(Conversation.first.status).to eq('snoozed')
        expect(Conversation.second.status).to eq('snoozed')
      end

      it 'Bulk update conversation labels' do
        params = { type: 'Conversation', ids: Conversation.first(3).pluck(:display_id), labels: { add: %w[support priority_customer] } }

        expect(Conversation.first.labels).to eq([])
        expect(Conversation.second.labels).to eq([])

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: params

          expect(response).to have_http_status(:success)
        end

        expect(Conversation.first.label_list).to contain_exactly('support', 'priority_customer')
        expect(Conversation.second.label_list).to contain_exactly('support', 'priority_customer')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/bulk_actions' do
    context 'when it is an authenticated user' do
      let!(:agent) { create(:user, account: account, role: :agent) }

      before do
        Conversation.all.find_each do |conversation|
          create(:inbox_member, inbox: conversation.inbox, user: agent)
        end
      end

      it 'Bulk delete conversation labels' do
        Conversation.first.add_labels(%w[support priority_customer])
        Conversation.second.add_labels(%w[support priority_customer])
        Conversation.third.add_labels(%w[support priority_customer])

        params = { type: 'Conversation', ids: Conversation.first(3).pluck(:display_id), labels: { remove: %w[support] } }

        expect(Conversation.first.label_list).to contain_exactly('support', 'priority_customer')
        expect(Conversation.second.label_list).to contain_exactly('support', 'priority_customer')

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: params

          expect(response).to have_http_status(:success)
        end

        expect(Conversation.first.label_list).to contain_exactly('priority_customer')
        expect(Conversation.second.label_list).to contain_exactly('priority_customer')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/bulk_actions (contacts)' do
    context 'when it is an authenticated user' do
      let!(:agent) { create(:user, account: account, role: :agent) }

      it 'enqueues Contacts::BulkActionJob with permitted params' do
        contact_one = create(:contact, account: account)
        contact_two = create(:contact, account: account)

        expect do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: {
                 type: 'Contact',
                 ids: [contact_one.id, contact_two.id],
                 labels: { add: %w[vip support] },
                 extra: 'ignored'
               }
        end.to have_enqueued_job(Contacts::BulkActionJob).with(
          account.id,
          agent.id,
          hash_including(
            'ids' => [contact_one.id.to_s, contact_two.id.to_s],
            'labels' => hash_including('add' => %w[vip support])
          )
        )

        expect(response).to have_http_status(:success)
      end

      it 'returns unauthorized for delete action when user is not admin' do
        contact = create(:contact, account: account)

        post "/api/v1/accounts/#{account.id}/bulk_actions",
             headers: agent.create_new_auth_token,
             params: {
               type: 'Contact',
               ids: [contact.id],
               action_name: 'delete'
             }

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
