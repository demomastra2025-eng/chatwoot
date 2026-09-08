require 'rails_helper'

RSpec.describe 'CRM Task lifecycle compatibility', type: :request do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:headers) { actor.create_new_auth_token }
  let(:task_type) { account.crm_task_types.find_by!(code: 'task') }
  let(:open_status) { account.crm_task_statuses.find_by!(code: 'todo') }
  let(:done_status) { account.crm_task_statuses.find_by!(code: 'done') }
  let(:cancelled_status) { account.crm_task_statuses.find_by!(category: 'cancelled') }
  let(:task) { create(:crm_task, account: account, task_type: task_type, status: open_status) }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/tasks/#{task.id}" }

  before do
    account.enable_features!('crm_deals', 'crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  def command(name, params = {})
    post "#{path}/#{name}", params: { lock_version: task.reload.lock_version }.merge(params), headers: headers, as: :json
  end

  it 'uses canonical completion metadata and replays the legacy request once' do
    params = { status_id: done_status.id, lock_version: task.lock_version, idempotency_key: 'legacy-complete' }
    command('change_status', params)
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(completed_by_id: actor.id, outcome: 'completed')
    expect(task.completed_at).to be_present
    version = task.lock_version

    command('change_status', params)
    expect(response).to have_http_status(:ok)
    expect(task.reload.lock_version).to eq(version)
    expect(task.events.where(event_type: 'task_completed').count).to eq(1)
  end

  it 'requires a reason for legacy cancellation and clears all terminal metadata when reopened', :aggregate_failures do
    command('change_status', status_id: cancelled_status.id)
    expect(response).to have_http_status(:unprocessable_content)
    command('change_status', status_id: cancelled_status.id, cancellation_reason: 'Not needed')
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(cancelled_by_id: actor.id, cancellation_reason: 'Not needed', outcome: 'cancelled')
    expect(task.cancelled_at).to be_present
    expect(task.events.where(event_type: 'task_cancelled').count).to eq(1)

    params = { status_id: open_status.id, lock_version: task.lock_version, idempotency_key: 'legacy-reopen' }
    command('change_status', params)
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(
      cancelled_at: nil, cancelled_by_id: nil, cancellation_reason: nil, task_outcome_id: nil,
      completed_at: nil, completed_by_id: nil, outcome: nil, outcome_note: nil
    )
    command('change_status', params)
    expect(response).to have_http_status(:ok)
    expect(task.events.where(event_type: 'task_reopened').count).to eq(1)
  end

  it 'preserves configured display statuses and positions without reporting another completion' do
    custom_done = create(:crm_task_status, account: account, category: 'done')
    command('complete')
    timestamp = task.reload.completed_at
    command('change_status', status_id: custom_done.id, position: 1)
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(status_id: custom_done.id, position: 1, completed_at: timestamp, completed_by_id: actor.id)
    expect(task.events.where(event_type: 'task_completed').count).to eq(1)
    expect(task.events.last.event_type).to eq('task_status_changed')
  end

  it 'preserves a custom completion result when moving between done display statuses' do
    outcome = create(:crm_task_outcome, account: account, task_type: task.task_type)
    custom_done = create(:crm_task_status, account: account, category: 'done')
    command('complete', task_outcome_id: outcome.id, outcome_note: 'Original result')
    expect(response).to have_http_status(:ok)
    timestamp = task.reload.completed_at

    command('change_status', status_id: custom_done.id, position: 1)
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(
      status_id: custom_done.id, task_outcome_id: outcome.id, outcome: outcome.code,
      outcome_note: 'Original result', completed_at: timestamp, completed_by_id: actor.id
    )
    expect(task.events.where(event_type: 'task_completed').count).to eq(1)
  end

  it 'retains an inactive completion result when only its note changes' do
    outcome = create(:crm_task_outcome, account: account, task_type: task.task_type)
    command('complete', task_outcome_id: outcome.id)
    expect(response).to have_http_status(:ok)
    outcome.update!(active: false)

    command('complete', outcome_note: 'Updated note')
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(task_outcome_id: outcome.id, outcome: outcome.code, outcome_note: 'Updated note')
  end

  it 'still accepts an explicitly requested replacement completion result' do
    outcome = create(:crm_task_outcome, account: account, task_type: task.task_type)
    command('complete', task_outcome_id: outcome.id)
    default_outcome = task.task_type.outcomes.active.find_by!(default: true)

    command('complete', task_outcome_id: default_outcome.id)
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(task_outcome_id: default_outcome.id, outcome: default_outcome.code)
  end

  it 'keeps active-status moves as status changes and retains the active task note' do
    progress = account.crm_task_statuses.find_by!(category: 'in_progress')
    task.update!(outcome_note: 'Draft note')
    command('change_status', status_id: progress.id, position: 1)
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(status_id: progress.id, outcome_note: 'Draft note')
    expect(task.events.last.event_type).to eq('task_status_changed')
  end

  it 'checks lock_version even when the legacy status request is a no-op' do
    command('change_status', status_id: open_status.id, lock_version: task.lock_version + 1)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('STALE_RECORD')
  end

  it 'reserves no-op keys without a new version or a false domain event', :aggregate_failures do
    version = task.lock_version
    params = { idempotency_key: 'noop-key', lock_version: version }
    command('reopen', params)
    expect(response).to have_http_status(:ok)
    expect(task.reload.lock_version).to eq(version)
    receipt = task.events.find_by!(command_key: 'noop-key')
    expect(receipt.event_type).to eq('task_command_noop')
    expect(Crm::Event::SUPPORTED_AUTOMATION_EVENT_TYPES).not_to include(receipt.event_type)

    task.update!(description: 'Changed later')
    command('reopen', params)
    expect(response).to have_http_status(:ok)
    expect(task.events.where(command_key: 'noop-key').count).to eq(1)
    command('complete', idempotency_key: 'noop-key')
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('IDEMPOTENCY_KEY_REUSED')
    expect(task.reload.status_id).to eq(open_status.id)
  end

  it 'rejects a different fingerprint after an accepted no-op' do
    command('assign', idempotency_key: 'assign-noop', assignee_id: task.assignee_id)
    expect(response).to have_http_status(:ok)
    command('assign', idempotency_key: 'assign-noop', assignee_id: actor.id)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('IDEMPOTENCY_KEY_REUSED')
  end

  it 'does not consume an idempotency key when validation fails' do
    command('cancel', idempotency_key: 'invalid-cancel')
    expect(response).to have_http_status(:unprocessable_content)
    expect(task.events.where(command_key: 'invalid-cancel')).not_to exist
    command('cancel', idempotency_key: 'invalid-cancel', cancellation_reason: 'Valid reason')
    expect(response).to have_http_status(:ok)
  end

  it 'keeps technical receipts out of the user timeline' do
    command('reopen', idempotency_key: 'hidden-noop')
    get "#{path}/timeline", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.to_json).not_to include('task_command_noop')
  end

  it 'rejects a status belonging to another account' do
    other_status = create(:crm_task_status)
    command('change_status', status_id: other_status.id)
    expect(response).to have_http_status(:not_found)
    expect(task.reload.status_id).to eq(open_status.id)
  end
end
