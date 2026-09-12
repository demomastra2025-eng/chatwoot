require 'rails_helper'

RSpec.describe Captain::CustomerTasks::Service do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:communication_thread) { create(:communication_thread, account: account, contact: contact) }
  let(:service) { described_class.new(assistant: assistant, conversation: conversation.reload) }

  before do
    account.enable_features!('crm_tasks')
    create(
      :communication_thread_conversation,
      communication_thread: communication_thread,
      conversation: conversation,
      primary: true
    )
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'lists only explicitly visible tasks from the current contact and thread with safe fields' do
    status = account.crm_task_statuses.find_by!(category: 'open')
    visible = create(
      :crm_task,
      account: account,
      status: status,
      originating_conversation: conversation,
      customer_visible: true,
      customer_title: 'Bring documents',
      customer_result: 'Accepted'
    )
    create(:crm_task, account: account, status: status, originating_conversation: conversation, customer_visible: false)
    other_contact = create(:contact, account: account)
    other_conversation = create(:conversation, account: account, contact: other_contact)
    other_thread = create(:communication_thread, account: account, contact: other_contact)
    create(:communication_thread_conversation, communication_thread: other_thread, conversation: other_conversation)
    create(
      :crm_task,
      account: account,
      status: status,
      originating_conversation: other_conversation,
      customer_visible: true,
      customer_title: 'Other customer'
    )

    result = service.call(action: 'list')

    expect(result[:tasks]).to eq(
      [{
        id: visible.id,
        title: 'Bring documents',
        status: 'open',
        result: 'Accepted',
        change_requested: false,
        cancellation_requested: false
      }]
    )
    expect(result.to_json).not_to include('assignee_id', 'team_id', 'comments')
  end

  it 'creates idempotently through the configured task-type route' do
    assignee = create(:user)
    create(:account_user, account: account, user: assignee)
    team = create(:team, account: account)
    create(:team_member, team: team, user: assignee)
    task_type = create(
      :crm_task_type,
      account: account,
      code: 'documents',
      customer_task_assignee: assignee,
      customer_task_team: team
    )

    first = service.call(
      action: 'create',
      title: 'Prepare certificate',
      task_type: task_type.code,
      due_at: 2.days.from_now.iso8601,
      idempotency_key: 'customer-task-create-1'
    )
    second = service.call(
      action: 'create',
      title: 'Prepare certificate',
      task_type: task_type.code,
      due_at: 2.days.from_now.iso8601,
      idempotency_key: 'customer-task-create-1'
    )
    task = account.crm_tasks.find(first.dig(:task, :id))

    expect(second.dig(:task, :id)).to eq(task.id)
    expect(task).to have_attributes(
      customer_visible: true,
      customer_title: 'Prepare certificate',
      assignee_id: assignee.id,
      team_id: team.id,
      originating_conversation_id: conversation.id
    )
  end

  it 'recovers a concurrent duplicate-key create as the original successful result' do
    assignee = create(:user)
    create(:account_user, account: account, user: assignee)
    team = create(:team, account: account)
    create(:team_member, team: team, user: assignee)
    task_type = create(
      :crm_task_type,
      account: account,
      code: 'concurrent-documents',
      customer_task_assignee: assignee,
      customer_task_team: team
    )
    existing_task = create(
      :crm_task,
      account: account,
      originating_conversation: conversation,
      customer_visible: true,
      customer_title: 'Prepare certificate',
      idempotency_key: 'customer-task-concurrent-1'
    )
    scoped_tasks = service.send(:customer_scope)
    allow(service).to receive(:customer_scope).and_return(scoped_tasks)
    allow(scoped_tasks).to receive(:find_by).with(idempotency_key: 'customer-task-concurrent-1')
                                            .and_return(nil, nil, existing_task)
    duplicate_error = Crm::Error.new(
      code: 'DUPLICATE_IDEMPOTENCY_KEY',
      message: 'idempotency_key must be unique within account',
      status: :conflict,
      details: { idempotency_key: ['has already been taken'] }
    )
    upsert_service = instance_double(Crm::Tasks::UpsertService)
    allow(Crm::Tasks::UpsertService).to receive(:new).and_return(upsert_service)
    allow(upsert_service).to receive(:perform).and_raise(duplicate_error)

    result = service.call(
      action: 'create',
      title: 'Prepare certificate',
      task_type: task_type.code,
      idempotency_key: 'customer-task-concurrent-1'
    )

    expect(result).to match(action: 'created', task: include(id: existing_task.id))
  end

  it 'recovers an idempotency uniqueness validation race' do
    assignee = create(:user)
    create(:account_user, account: account, user: assignee)
    team = create(:team, account: account)
    create(:team_member, team: team, user: assignee)
    task_type = create(
      :crm_task_type,
      account: account,
      code: 'validation-race',
      customer_task_assignee: assignee,
      customer_task_team: team
    )
    existing_task = create(
      :crm_task,
      account: account,
      originating_conversation: conversation,
      customer_visible: true,
      customer_title: 'Validation race',
      idempotency_key: 'customer-task-validation-race-1'
    )
    invalid_task = account.crm_tasks.new(idempotency_key: 'customer-task-validation-race-1')
    invalid_task.errors.add(:idempotency_key, :taken)
    scoped_tasks = service.send(:customer_scope)
    allow(service).to receive(:customer_scope).and_return(scoped_tasks)
    allow(scoped_tasks).to receive(:find_by).and_return(nil, existing_task)
    upsert_service = instance_double(Crm::Tasks::UpsertService)
    allow(Crm::Tasks::UpsertService).to receive(:new).and_return(upsert_service)
    allow(upsert_service).to receive(:perform).and_raise(ActiveRecord::RecordInvalid.new(invalid_task))

    result = service.call(
      action: 'create', title: 'Validation race', task_type: task_type.code,
      idempotency_key: 'customer-task-validation-race-1'
    )

    expect(result).to match(action: 'created', task: include(id: existing_task.id))
  end

  it 'rejects unrelated uniqueness and mixed validation failures from duplicate recovery' do
    pg_result = instance_double(PG::Result)
    allow(pg_result).to receive(:error_field)
      .with(PG::Result::PG_DIAG_CONSTRAINT_NAME)
      .and_return('index_crm_tasks_on_account_external_ref')
    pg_error = instance_double(PG::UniqueViolation, result: pg_result)
    unrelated_unique_error = ActiveRecord::RecordNotUnique.new('external_ref conflict')
    allow(unrelated_unique_error).to receive(:cause).and_return(pg_error)

    invalid_task = account.crm_tasks.new(idempotency_key: 'mixed-errors-1')
    invalid_task.errors.add(:idempotency_key, :taken)
    invalid_task.errors.add(:title, :blank)
    mixed_validation_error = ActiveRecord::RecordInvalid.new(invalid_task)

    expect(service.send(:recoverable_idempotency_error?, unrelated_unique_error, 'mixed-errors-1')).to be(false)
    expect(service.send(:recoverable_idempotency_error?, mixed_validation_error, 'mixed-errors-1')).to be(false)
  end

  it 'rejects idempotency-looking failures for another account or domain detail' do
    other_account = create(:account)
    other_task = other_account.crm_tasks.new(idempotency_key: 'expected-key')
    other_task.errors.add(:idempotency_key, :taken)
    other_account_error = ActiveRecord::RecordInvalid.new(other_task)
    wrong_key_task = account.crm_tasks.new(idempotency_key: 'another-key')
    wrong_key_task.errors.add(:idempotency_key, :taken)
    wrong_key_error = ActiveRecord::RecordInvalid.new(wrong_key_task)
    wrong_record = account.crm_deals.new(idempotency_key: 'expected-key')
    wrong_record.errors.add(:idempotency_key, :taken)
    wrong_record_error = ActiveRecord::RecordInvalid.new(wrong_record)
    wrong_detail_error = Crm::Error.new(
      code: 'DUPLICATE_IDEMPOTENCY_KEY',
      message: 'duplicate',
      status: :conflict,
      details: { external_ref: ['has already been taken'] }
    )

    expect(service.send(:recoverable_idempotency_error?, other_account_error, 'expected-key')).to be(false)
    expect(service.send(:recoverable_idempotency_error?, wrong_key_error, 'expected-key')).to be(false)
    expect(service.send(:recoverable_idempotency_error?, wrong_record_error, 'expected-key')).to be(false)
    expect(service.send(:recoverable_idempotency_error?, wrong_detail_error, 'expected-key')).to be(false)
  end

  it 'records change and cancellation requests instead of mutating an in-progress task' do
    status = account.crm_task_statuses.find_by!(category: 'in_progress')
    task = create(
      :crm_task,
      account: account,
      status: status,
      originating_conversation: conversation,
      customer_visible: true,
      customer_title: 'Original title'
    )

    update_result = service.call(
      action: 'update',
      task_id: task.id,
      title: 'Changed title',
      request_reason: 'Please move the deadline',
      idempotency_key: 'customer-task-update-1'
    )
    cancel_result = service.call(
      action: 'cancel',
      task_id: task.id,
      request_reason: 'No longer needed',
      idempotency_key: 'customer-task-cancel-1'
    )
    task.reload

    expect(update_result[:action]).to eq('change_requested')
    expect(cancel_result[:action]).to eq('cancellation_requested')
    expect(task.customer_title).to eq('Original title')
    expect(task.customer_change_request).to eq('Please move the deadline')
    expect(task.customer_cancellation_request).to eq('No longer needed')
    expect(task.cancelled_at).to be_nil
  end

  it 'reuses in-progress update and cancellation commands with stable intent fingerprints' do
    status = account.crm_task_statuses.find_by!(category: 'in_progress')
    task = create(
      :crm_task,
      account: account,
      status: status,
      originating_conversation: conversation,
      customer_visible: true,
      customer_title: 'Original title'
    )
    update_params = {
      action: 'update', task_id: task.id, request_reason: 'Change it', idempotency_key: 'stable-update-1'
    }
    cancel_params = {
      action: 'cancel', task_id: task.id, request_reason: 'Cancel it', idempotency_key: 'stable-cancel-1'
    }

    first_update = service.call(**update_params)
    first_update_at = task.reload.customer_change_requested_at
    travel 1.minute
    second_update = service.call(**update_params)

    expect(second_update).to eq(first_update)
    expect(task.reload.customer_change_requested_at).to eq(first_update_at)

    first_cancel = service.call(**cancel_params)
    first_cancel_at = task.reload.customer_cancellation_requested_at
    travel 1.minute
    second_cancel = service.call(**cancel_params)

    expect(second_cancel).to eq(first_cancel)
    expect(task.reload.customer_cancellation_requested_at).to eq(first_cancel_at)
    expect(task.events.where(command_key: %w[stable-update-1 stable-cancel-1]).count).to eq(2)
  end

  it 'does not update or cancel a completed task' do
    status = account.crm_task_statuses.find_by!(category: 'done')
    task = create(
      :crm_task,
      account: account,
      status: status,
      originating_conversation: conversation,
      customer_visible: true,
      customer_title: 'Completed task'
    )

    update_result = service.call(
      action: 'update',
      task_id: task.id,
      title: 'Changed title',
      idempotency_key: 'customer-task-done-update-1'
    )
    cancel_result = service.call(
      action: 'cancel',
      task_id: task.id,
      idempotency_key: 'customer-task-done-cancel-1'
    )

    expect(update_result[:action]).to eq('update_ignored')
    expect(cancel_result[:action]).to eq('cancel_ignored')
    expect(task.reload).to have_attributes(customer_title: 'Completed task', cancelled_at: nil)
  end

  it 'rejects a task id from another contact instead of exposing its existence' do
    other_contact = create(:contact, account: account)
    other_conversation = create(:conversation, account: account, contact: other_contact)
    task = create(
      :crm_task,
      account: account,
      originating_conversation: other_conversation,
      customer_visible: true,
      customer_title: 'Private task'
    )

    expect do
      service.call(action: 'update', task_id: task.id, title: 'Probe', idempotency_key: 'probe-1')
    end.to raise_error(ActiveRecord::RecordNotFound)
  end
end
