require 'rails_helper'

RSpec.describe 'CRM atomic task form', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:task) { create(:crm_task, account: account, title: 'Original') }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/tasks/#{task.id}/save_form" }
  let(:key) { SecureRandom.uuid }
  let(:command) { { idempotency_key: key, lock_version: task.lock_version } }

  before do
    account.enable_features!('crm_deals', 'crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  def save_form(attributes)
    post path, params: attributes, headers: headers, as: :json
  end

  it 'commits details, assignment and schedule together with a command receipt' do
    assignee = create(:user, account: account)
    save_form(command.merge(title: 'Saved', assignee_id: assignee.id, all_day: true, due_on: '2026-10-01'))

    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(title: 'Saved', assignee_id: assignee.id, all_day: true, due_on: Date.new(2026, 10, 1))
    expect(task.reschedule_count).to eq(1)
    expect(task.events.find_by!(command_key: key).event_type).to eq('task_form_saved')
  end

  it 'rolls back earlier details and audit facts when assignment is cross-account' do
    foreign_user = create(:user)
    task
    before_events = task.events.count
    save_form(command.merge(title: 'Must roll back', assignee_id: foreign_user.id))

    expect(response).to have_http_status(:not_found)
    expect(task.reload.title).to eq('Original')
    expect(task.events.count).to eq(before_events)
    expect(task.events.find_by(command_key: key)).to be_nil
  end

  it 'rolls back details and assignment when the schedule is invalid' do
    assignee = create(:user, account: account)
    version = task.lock_version
    save_form(command.merge(title: 'Must roll back', assignee_id: assignee.id, all_day: true, due_on: nil))

    expect(response).to have_http_status(:unprocessable_content)
    expect(task.reload).to have_attributes(title: 'Original', assignee_id: nil, lock_version: version, reschedule_count: 0)
    expect(task.events.find_by(command_key: key)).to be_nil
    expect(Notification.where(primary_actor: task, notification_type: 'task_assignment')).to be_empty
  end

  it 'rolls back the form when the final status command requires a result note' do
    outcome = task.task_type.outcomes.find_by!(code: 'other')
    status = account.crm_task_statuses.find_by!(code: 'done')
    save_form(command.merge(title: 'Must roll back', status_id: status.id, task_outcome_id: outcome.id))

    expect(response).to have_http_status(:unprocessable_content)
    expect(task.reload.title).to eq('Original')
    expect(task.completed_at).to be_nil
  end

  it 'completes through the lifecycle service using fields saved in the same form' do
    status = account.crm_task_statuses.find_by!(code: 'done')
    outcome = task.task_type.outcomes.find_by!(code: 'other')
    save_form(command.merge(title: 'Complete', status_id: status.id, task_outcome_id: outcome.id, outcome_note: 'Checked'))

    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(title: 'Complete', completed_by_id: administrator.id, task_outcome_id: outcome.id)
    expect(task.completed_at).to be_present
  end

  it 'replays a successful command before checking its now-stale lock version' do
    request = command.merge(title: 'Saved', all_day: true, due_on: '2026-10-01')
    save_form(request)
    expect(response).to have_http_status(:ok)
    version = task.reload.lock_version
    event_count = task.events.count
    save_form(request)

    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(lock_version: version, reschedule_count: 1)
    expect(task.events.count).to eq(event_count)
  end

  it 'rejects reuse of a command key for a different draft' do
    request = command.merge(title: 'First')
    save_form(request)
    expect(response).to have_http_status(:ok)
    save_form(request.merge(title: 'Second'))

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('IDEMPOTENCY_KEY_REUSED')
    expect(task.reload.title).to eq('First')
  end

  it 'rejects a stale form without changing any fields' do
    request = command.merge(title: 'Stale')
    task.update!(title: 'Other editor')
    save_form(request)

    expect(response).to have_http_status(:conflict)
    expect(task.reload.title).to eq('Other editor')
  end

  it 'requires an explicit command key and a valid lock version' do
    save_form(title: 'Invalid', lock_version: task.lock_version)
    expect(response).to have_http_status(:unprocessable_content)
    save_form(command.merge(lock_version: 'garbage'))
    expect(response).to have_http_status(:unprocessable_content)
    expect(task.reload.title).to eq('Original')
  end

  it 'does not expose a task from another account' do
    other = create(:crm_task)
    post "/api/v1/accounts/#{account.id}/crm/tasks/#{other.id}/save_form",
         params: { title: 'Forbidden', lock_version: other.lock_version, idempotency_key: key }, headers: headers, as: :json

    expect(response).to have_http_status(:not_found)
  end

  it 'requires authentication' do
    post path, params: command.merge(title: 'Forbidden'), as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(task.reload.title).to eq('Original')
  end
end
