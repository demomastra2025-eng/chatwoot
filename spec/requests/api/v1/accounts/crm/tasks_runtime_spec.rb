require 'rails_helper'

RSpec.describe 'CRM Tasks Runtime API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/tasks" }

  before do
    account.enable_features!('crm_deals')
    account.enable_features!('crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'creates a deal task and defaults assignee/team from the deal' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    stage = pipeline.stages.find_by!(code: 'new')
    owner = create(:user, account: account, role: :agent)
    team = create(:team, account: account)
    company = create(:company, account: account)
    conversation = create(:conversation, account: account)
    deal = create(
      :crm_deal,
      account: account,
      pipeline: pipeline,
      stage: stage,
      owner: owner,
      team: team,
      company: company,
      originating_conversation: conversation
    )

    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'task',
      key: 'follow_up_reason',
      label: 'Follow-up reason',
      field_type: 'text',
      default_value: 'documents',
      rules: { contexts: ['deal_task'] }
    )

    post path,
         params: {
           deal_id: deal.id,
           title: 'Send contract'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'assignee_id')).to eq(owner.id)
    expect(response.parsed_body.dig('payload', 'team_id')).to eq(team.id)
    expect(response.parsed_body.dig('payload', 'originating_conversation_id')).to eq(conversation.id)
    expect(response.parsed_body.dig('payload', 'custom_attributes', 'follow_up_reason')).to eq('documents')
  end

  it 'creates a standalone task with originating conversation id' do
    conversation = create(:conversation, account: account)

    post path,
         params: {
           title: 'Call back from inbox',
           originating_conversation_id: conversation.id
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'originating_conversation_id')).to eq(conversation.id)
  end

  it 'does not auto-assign an inactive default status to new tasks' do
    default_status = account.crm_task_statuses.find_by!(code: 'todo')
    default_status.update!(active: false, default: true)

    post path,
         params: {
           title: 'Fallback active status'
         },
         headers: headers,
         as: :json

    created_task = account.crm_tasks.find(response.parsed_body.dig('payload', 'id'))

    expect(response).to have_http_status(:created)
    expect(created_task.status_id).not_to eq(default_status.id)
    expect(created_task.status.active).to eq(true)
  end

  it 'returns an existing task when create is retried with the same idempotency_key' do
    params = {
      title: 'Imported follow-up',
      idempotency_key: 'task-import-1'
    }

    post path, params: params, headers: headers, as: :json
    first_id = response.parsed_body.dig('payload', 'id')

    post path, params: params, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'id')).to eq(first_id)
  end

  it 'filters tasks by priority' do
    high_priority_task = create(
      :crm_task,
      account: account,
      status: account.crm_task_statuses.find_by!(code: 'todo'),
      priority: 'high',
      title: 'Escalate renewal'
    )
    create(
      :crm_task,
      account: account,
      status: account.crm_task_statuses.find_by!(code: 'todo'),
      priority: 'low',
      title: 'Send follow-up note'
    )

    get path, params: { priority: 'high' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload'].map { |task| task['id'] }).to eq([high_priority_task.id])
  end

  it 'changes status to done and sets completed_at' do
    open_status = account.crm_task_statuses.find_by!(code: 'todo')
    done_status = account.crm_task_statuses.find_by!(code: 'done')
    task = create(:crm_task, account: account, status: open_status)

    post "#{path}/#{task.id}/change_status",
         params: { status_id: done_status.id, lock_version: task.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status_id')).to eq(done_status.id)
    expect(response.parsed_body.dig('payload', 'completed_at')).to be_present
    expect(task.reload.events.where(event_type: 'task_status_changed')).to exist
  end

  it 'rejects unknown custom fields' do
    post path,
         params: {
           title: 'Invalid custom field',
           custom_attributes: { unsupported_key: 'value' }
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('VALIDATION_ERROR')
  end

  it 'archives and unarchives a task' do
    task = create(:crm_task, account: account, status: account.crm_task_statuses.find_by!(code: 'todo'))

    post "#{path}/#{task.id}/archive",
         params: { lock_version: task.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'archived_at')).to be_present

    post "#{path}/#{task.id}/unarchive",
         params: { lock_version: task.reload.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'archived_at')).to be_nil
  end

  it 'drops custom field values when their field definition is deleted' do
    field_definition = create(
      :crm_field_definition,
      account: account,
      entity_kind: 'task',
      key: 'follow_up_reason',
      label: 'Follow-up reason'
    )
    task = create(
      :crm_task,
      account: account,
      status: account.crm_task_statuses.find_by!(code: 'todo'),
      custom_attributes: { 'follow_up_reason' => 'documents' }
    )

    delete "/api/v1/accounts/#{account.id}/crm/field_definitions/#{field_definition.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:no_content)

    patch "#{path}/#{task.id}",
          params: {
            title: 'Updated task title',
            lock_version: task.lock_version
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'custom_attributes')).to eq({})
    expect(task.reload.custom_attributes).to eq({})
  end
end
