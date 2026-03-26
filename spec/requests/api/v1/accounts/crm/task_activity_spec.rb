require 'rails_helper'

RSpec.describe 'CRM Task Activity API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:task_path) { "/api/v1/accounts/#{account.id}/crm/tasks" }

  before do
    account.enable_features!('crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'creates, updates, lists, and soft-deletes task comments' do
    task = create(:crm_task, account: account, status: account.crm_task_statuses.find_by!(code: 'todo'))
    comments_path = "#{task_path}/#{task.id}/comments"

    post comments_path, params: { body: 'Waiting for callback' }, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    comment_id = response.parsed_body.dig('payload', 'id')

    patch "#{comments_path}/#{comment_id}",
          params: { body: 'Waiting for callback after 16:00' },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'body')).to eq('Waiting for callback after 16:00')

    get comments_path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)

    delete "#{comments_path}/#{comment_id}", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(task.comments.find(comment_id).deleted_at).to be_present
  end

  it 'returns task timeline items without conversation payloads' do
    task = create(:crm_task, account: account, status: account.crm_task_statuses.find_by!(code: 'todo'))
    create(:crm_comment, account: account, commentable: task, user: administrator, body: 'Escalated to senior agent')
    create(:crm_event, account: account, eventable: task, actor: administrator, event_type: 'task_reopened')

    get "#{task_path}/#{task.id}/timeline", headers: headers, as: :json

    expect(response).to have_http_status(:ok)

    item_types = response.parsed_body.fetch('payload').map { |item| item['item_type'] }
    expect(item_types).to include('event', 'comment')
    expect(item_types).not_to include('conversation')
  end

  it 'returns the originating conversation in task timeline when permitted' do
    custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view conversation_manage])
    custom_role_user = create(:user, account: account, role: :agent)
    custom_role_user.account_users.find_by(account: account).update!(custom_role: custom_role)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    create(:inbox_member, user: custom_role_user, inbox: conversation.inbox)
    task = create(
      :crm_task,
      account: account,
      status: account.crm_task_statuses.find_by!(code: 'todo'),
      originating_conversation: conversation
    )

    get "#{task_path}/#{task.id}/timeline",
        headers: custom_role_user.create_new_auth_token,
        as: :json

    expect(response).to have_http_status(:ok)
    conversation_payload = response.parsed_body.fetch('payload').find do |item|
      item['item_type'] == 'conversation'
    end

    expect(conversation_payload.dig('payload', 'id')).to eq(conversation.id)
  end
end
