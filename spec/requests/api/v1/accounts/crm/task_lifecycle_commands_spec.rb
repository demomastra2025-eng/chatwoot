require 'rails_helper'

RSpec.describe 'CRM Task lifecycle commands', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/tasks" }
  let(:todo_status) { account.crm_task_statuses.find_by!(code: 'todo') }
  let(:task_type) { account.crm_task_types.find_by!(code: 'task') }
  let(:task) { create(:crm_task, account: account, status: todo_status, task_type: task_type) }

  before do
    account.enable_features!('crm_deals')
    account.enable_features!('crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'completes a task with a configured outcome and records the actor' do
    outcome = task_type.outcomes.find_by!(code: 'completed')

    post "#{path}/#{task.id}/complete",
         params: command_params(task).merge(task_outcome_id: outcome.id, outcome_note: 'Done'),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(
      task_outcome_id: outcome.id,
      outcome: 'completed',
      outcome_note: 'Done',
      completed_by_id: administrator.id,
      cancelled_at: nil
    )
    expect(task.completed_at).to be_present
    expect(task.status.category).to eq('done')
    expect(task.events.last.event_type).to eq('task_completed')
  end

  it 'enforces note-required outcomes in command and legacy status APIs' do
    outcome = task_type.outcomes.find_by!(code: 'other')
    done_status = account.crm_task_statuses.find_by!(code: 'done')

    post "#{path}/#{task.id}/complete",
         params: command_params(task).merge(task_outcome_id: outcome.id), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)

    post "#{path}/#{task.id}/change_status",
         params: {
           status_id: done_status.id,
           lock_version: task.reload.lock_version,
           outcome: outcome.code
         },
         headers: headers,
         as: :json
    expect(response).to have_http_status(:unprocessable_content)

    post "#{path}/#{task.id}/change_status",
         params: {
           status_id: done_status.id,
           lock_version: task.reload.lock_version,
           outcome: outcome.code,
           outcome_note: 'Custom result'
         },
         headers: headers,
         as: :json
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(task_outcome: outcome, outcome_note: 'Custom result')
  end

  it 'requires a cancellation reason and transitions to the cancelled state' do
    post "#{path}/#{task.id}/cancel",
         params: command_params(task), headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)

    post "#{path}/#{task.id}/cancel",
         params: command_params(task.reload).merge(cancellation_reason: 'No longer relevant'),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(
      cancellation_reason: 'No longer relevant',
      cancelled_by_id: administrator.id,
      completed_at: nil
    )
    expect(task.cancelled_at).to be_present
    expect(task.status.category).to eq('cancelled')
  end

  it 'reopens a completed task and clears its terminal result' do
    outcome = task_type.outcomes.find_by!(code: 'completed')
    post "#{path}/#{task.id}/complete",
         params: command_params(task).merge(task_outcome_id: outcome.id), headers: headers, as: :json

    post "#{path}/#{task.id}/reopen",
         params: command_params(task.reload), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(
      task_outcome_id: nil,
      outcome: nil,
      outcome_note: nil,
      completed_at: nil,
      completed_by_id: nil,
      cancelled_at: nil,
      cancelled_by_id: nil,
      cancellation_reason: nil
    )
    expect(task.status.category).not_to be_in(%w[done cancelled])
  end

  it 'reschedules and assigns an open task through explicit commands' do
    assignee = create(:user, account: account, role: :agent)

    post "#{path}/#{task.id}/reschedule",
         params: command_params(task).merge(
           all_day: false,
           due_at: '2026-09-10T12:30:00+05:00',
           schedule_timezone: 'Asia/Almaty'
         ),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(task.reload.reschedule_count).to eq(1)
    expect(task.due_at).to eq(Time.iso8601('2026-09-10T07:30:00Z'))

    post "#{path}/#{task.id}/assign",
         params: command_params(task).merge(assignee_id: assignee.id), headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(task.reload.assignee).to eq(assignee)
    expect(task.events.order(:id).last(2).map(&:event_type)).to eq(%w[task_rescheduled task_assigned])
  end

  it 'returns the same task for an identical command key and rejects key reuse' do
    outcome = task_type.outcomes.find_by!(code: 'completed')
    payload = command_params(task).merge(task_outcome_id: outcome.id)

    post "#{path}/#{task.id}/complete", params: payload, headers: headers, as: :json
    resulting_version = response.parsed_body.dig('payload', 'lock_version')

    post "#{path}/#{task.id}/complete", params: payload, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'lock_version')).to eq(resulting_version)

    post "#{path}/#{task.id}/cancel",
         params: payload.merge(cancellation_reason: 'Changed command'), headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('IDEMPOTENCY_KEY_REUSED')
  end

  def command_params(record)
    {
      idempotency_key: SecureRandom.uuid,
      lock_version: record.lock_version
    }
  end
end
