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

  def create_accessible_thread(account:, user:)
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    thread = create(:communication_thread, account: account, contact: contact)
    conversation = create(:conversation, account: account, contact: contact)
    CommunicationThreadConversation.where(account_id: account.id, conversation_id: conversation.id).delete_all
    conversation.association(:communication_thread_conversation).reset
    conversation.association(:communication_thread).reset
    create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
    create(:inbox_member, inbox: conversation.inbox, user: user) unless InboxMember.exists?(inbox_id: conversation.inbox_id, user_id: user.id)
    [thread, conversation]
  end

  # Runs a captured job like the queue does: its arguments go through ActiveJob serialization.
  def perform_queued(arguments)
    BulkActionsJob.perform_now(**ActiveJob::Arguments.deserialize(ActiveJob::Arguments.serialize([arguments])).first)
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

      describe 'POST /api/v1/accounts/{account.id}/bulk_actions/selection' do
        it 'returns only a bounded signed snapshot for the matching list' do
          post "/api/v1/accounts/#{account.id}/bulk_actions/selection",
               headers: agent.create_new_auth_token,
               params: {
                 type: 'Conversation',
                 filters: { mode: 'basic', status: 'all' }
               }

          expect(response).to have_http_status(:success)
          payload = response.parsed_body.fetch('payload')
          expect(payload.fetch('count')).to eq(4)
          expect(payload.fetch('ids')).to match_array(account.conversations.pluck(:display_id))
          expect(payload.fetch('token')).to be_present
          expect(payload.fetch('inbox_ids')).to match_array(account.conversations.pluck(:inbox_id))
          expect(payload.fetch('inbox_ids_by_id').keys).to match_array(payload.fetch('ids').map(&:to_s))
          expect(payload).not_to include('conversations', 'record_ids')
        end

        it 'uses the server search input for the signed selection' do
          matching = account.conversations.first
          create(:message, conversation: matching, account: account, content: 'snapshot search needle')
          post "/api/v1/accounts/#{account.id}/bulk_actions/selection",
               headers: agent.create_new_auth_token,
               params: {
                 type: 'Conversation',
                 filters: { mode: 'basic', status: 'resolved', q: 'snapshot search needle' }
               }

          expect(response).to have_http_status(:success)
          expect(response.parsed_body.dig('payload', 'ids')).to eq([matching.display_id])
        end
      end

      it 'Ignores bulk_actions for wrong type' do
        post "/api/v1/accounts/#{account.id}/bulk_actions",
             headers: agent.create_new_auth_token,
             params: { type: 'Test', fields: { status: 'snoozed' }, ids: %w[1 2 3] }

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'Bulk update conversation status' do
        expect([Conversation.first.status, Conversation.last.status]).to eq(%w[open open])
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

        post "/api/v1/accounts/#{account.id}/bulk_actions",
             headers: agent.create_new_auth_token,
             params: { type: 'CommunicationThread', fields: { status: 'resolved' }, ids: [thread.display_id] }

        expect(response).to have_http_status(:success)
        expect(response.parsed_body.dig('payload', 'resource_type')).to eq('CommunicationThread')
        expect(response.parsed_body.dig('payload', 'action_name')).to eq('update_status')
      end

      it 'does not apply a pre-enqueue snapshot to a replacement thread with a reused display ID' do
        auth_headers = agent.create_new_auth_token
        original, original_conversation = create_accessible_thread(account: account, user: agent)
        filters = { mode: 'basic', status: 'all', inbox_id: original_conversation.inbox_id }
        post "/api/v1/accounts/#{account.id}/bulk_actions/selection",
             headers: auth_headers,
             params: { type: 'CommunicationThread', filters: filters }
        expect(response).to have_http_status(:success)
        token = response.parsed_body.dig('payload', 'token')

        original_id = original.id
        original_display_id = original.display_id
        original.destroy!
        replacement, replacement_conversation = create_accessible_thread(account: account, user: agent)
        expect(replacement.display_id).to eq(original_display_id)

        queued_arguments = nil
        expect(BulkActionsJob).to receive(:perform_later) do |**arguments|
          queued_arguments = arguments
        end
        post "/api/v1/accounts/#{account.id}/bulk_actions",
             headers: auth_headers,
             params: {
               type: 'CommunicationThread',
               selection_token: token,
               fields: { status: 'resolved' }
             }

        expect(response).to have_http_status(:success)
        expect(queued_arguments.fetch(:params)[:record_ids]).to eq([original_id])
        perform_queued(queued_arguments)

        expect([replacement.reload.status, replacement_conversation.reload.status]).to eq(%w[open open])
        run = account.bulk_action_runs.find(queued_arguments.fetch(:bulk_action_run_id))
        expect(run.as_progress_json[:skipped_count]).to eq(1)
      end

      it 'does not apply an enqueued snapshot to a replacement thread with a reused display ID' do
        auth_headers = agent.create_new_auth_token
        original, original_conversation = create_accessible_thread(account: account, user: agent)
        post "/api/v1/accounts/#{account.id}/bulk_actions/selection",
             headers: auth_headers,
             params: {
               type: 'CommunicationThread',
               filters: { mode: 'basic', status: 'all', inbox_id: original_conversation.inbox_id }
             }
        expect(response).to have_http_status(:success)
        token = response.parsed_body.dig('payload', 'token')

        original_id = original.id
        original_display_id = original.display_id
        queued_arguments = nil
        expect(BulkActionsJob).to receive(:perform_later) do |**arguments|
          queued_arguments = arguments
        end
        post "/api/v1/accounts/#{account.id}/bulk_actions",
             headers: auth_headers,
             params: {
               type: 'CommunicationThread',
               selection_token: token,
               fields: { status: 'resolved' }
             }

        expect(response).to have_http_status(:success)
        expect(queued_arguments.fetch(:params)[:record_ids]).to eq([original_id])

        original.destroy!
        replacement, replacement_conversation = create_accessible_thread(account: account, user: agent)
        expect(replacement.display_id).to eq(original_display_id)
        perform_queued(queued_arguments)

        expect([replacement.reload.status, replacement_conversation.reload.status]).to eq(%w[open open])
        run = account.bulk_action_runs.find(queued_arguments.fetch(:bulk_action_run_id))
        expect(run.as_progress_json[:skipped_count]).to eq(1)
      end

      it 'uses only IDs from the signed snapshot and honors explicit exclusions' do
        snapshot = BulkActions::SelectionSnapshot.new(
          account: account,
          user: agent,
          resource_type: 'Conversation',
          filters: { mode: 'basic', status: 'all' }
        ).perform
        excluded_id = snapshot.ids.first
        included_ids = snapshot.ids - [excluded_id]

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: {
                 type: 'Conversation',
                 selection_token: snapshot.token,
                 excluded_ids: [excluded_id],
                 fields: { status: 'snoozed' }
               }

          expect(response).to have_http_status(:success)
          expect(response.parsed_body.dig('payload', 'metadata', 'selected_count')).to eq(included_ids.size)
        end

        expect(account.conversations.find_by!(display_id: excluded_id).status).to eq('open')
        expect(account.conversations.where(display_id: included_ids).pluck(:status).uniq).to eq(['snoozed'])
      end

      it 'rejects count, filter, and ID changes alongside a signed snapshot' do
        snapshot = BulkActions::SelectionSnapshot.new(
          account: account, user: agent, resource_type: 'Conversation', filters: { status: 'all' }
        ).perform

        [{ count: 1 }, { filters: { status: 'resolved' } }, { ids: [snapshot.ids.first] }].each do |change|
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: {
                 type: 'Conversation', selection_token: snapshot.token, fields: { status: 'resolved' }
               }.merge(change)

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body.dig('error', 'code')).to eq('selection_invalid')
        end
      end

      it 'rejects an expired snapshot with a stable selection error code' do
        snapshot = BulkActions::SelectionSnapshot.new(
          account: account,
          user: agent,
          resource_type: 'Conversation',
          filters: { mode: 'basic', status: 'all' }
        ).perform

        travel 6.minutes do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: {
                 type: 'Conversation',
                 selection_token: snapshot.token,
                 fields: { status: 'snoozed' }
               }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.parsed_body.dig('error', 'code')).to eq('selection_invalid')
        end
      end

      it 'preserves the configured close reason through the controller and background job' do
        account.update!(
          conversation_status_reason_config: {
            'resolved' => { options: ['Resolved by request'], required: true }
          }
        )
        conversation = account.conversations.first

        perform_enqueued_jobs do
          post "/api/v1/accounts/#{account.id}/bulk_actions",
               headers: agent.create_new_auth_token,
               params: {
                 type: 'Conversation',
                 ids: [conversation.display_id],
                 fields: { status: 'resolved', status_reason: 'Resolved by request' }
               }

          expect(response).to have_http_status(:success)
        end

        expect(conversation.reload.status).to eq('resolved')
        expect(conversation.status_transitions.last.reason).to eq('Resolved by request')
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
        expect([Conversation.first.assignee_id, Conversation.second.assignee_id]).to eq([nil, nil])

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
        expect([Conversation.first.assignee_id, Conversation.second.assignee_id]).to eq([agent_1.id, agent_2.id])

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
