require 'rails_helper'

RSpec.describe Crm::Tasks::UpsertService do
  let(:account) { create(:account) }
  let(:status) { create(:crm_task_status, account: account, category: 'open') }
  let(:deal_team) { create(:team, account: account) }
  let(:deal) { create(:crm_deal, account: account, team: deal_team) }

  before { account.enable_features!('crm_tasks') }

  it 'inherits the team from its deal' do
    task = described_class.new(
      account: account,
      params: {
        deal_id: deal.id,
        status_id: status.id,
        title: 'Prepare proposal'
      }
    ).perform

    expect(task.team).to eq(deal_team)
    expect(task.context_kind).to eq('sales')
  end

  it 'creates a personal task for a legacy standalone request' do
    task = described_class.new(
      account: account,
      params: { status_id: status.id, title: 'Personal follow-up' }
    ).perform

    expect(task).to have_attributes(context_kind: 'personal', deal_id: nil)
  end

  it 'repairs catalog and context fields left null by an old writer on update' do
    task = create(
      :crm_task,
      account: account,
      status: status,
      activity_type: 'call',
      outcome: 'answered',
      outcome_note: 'Reached the client'
    )
    # rubocop:disable Rails/SkipsModelValidations -- Simulates a mixed-version writer against the expand schema.
    task.update_columns(task_type_id: nil, context_kind: nil)
    # rubocop:enable Rails/SkipsModelValidations

    updated_task = described_class.new(
      account: account,
      task: task.reload,
      params: { lock_version: task.lock_version, title: 'Updated by new writer' }
    ).perform

    expect(updated_task).to have_attributes(
      title: 'Updated by new writer',
      context_kind: 'personal',
      task_type_id: account.crm_task_types.find_by!(code: 'call').id,
      task_outcome_id: account.crm_task_types.find_by!(code: 'call').outcomes.find_by!(code: 'answered').id,
      outcome: 'answered',
      outcome_note: 'Reached the client'
    )
  end

  it 'rejects an explicit sales context without a deal' do
    request = lambda do
      described_class.new(
        account: account,
        params: { context_kind: 'sales', status_id: status.id, title: 'Orphan sales task' }
      ).perform
    end

    expect(&request).to raise_error(Crm::Error) do |error|
      expect(error.code).to eq('VALIDATION_ERROR')
      expect(error.details).to eq('deal_id' => ['is required for sales tasks'])
    end
  end

  it 'uses explicit context rather than deal presence for custom fields' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'task',
      key: 'sales_note',
      default_value: 'sales',
      rules: { contexts: ['deal_task'] }
    )
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'task',
      key: 'personal_note',
      default_value: 'personal',
      rules: { contexts: ['standalone_task'] }
    )

    task = described_class.new(
      account: account,
      params: {
        context_kind: 'personal',
        deal_id: deal.id,
        status_id: status.id,
        title: 'Personal task linked for reference'
      }
    ).perform

    expect(task.custom_attributes).to include('personal_note' => 'personal')
    expect(task.custom_attributes).not_to have_key('sales_note')
  end

  it 'rejects a team override for a linked task' do
    other_team = create(:team, account: account)
    task = create(:crm_task, account: account, deal: deal, status: status, team: deal_team)

    request = lambda do
      described_class.new(
        account: account,
        task: task,
        params: {
          lock_version: task.lock_version,
          team_id: other_team.id
        }
      ).perform
    end

    expect(&request).to raise_error(Crm::Error) do |error|
      expect(error.code).to eq('VALIDATION_ERROR')
      expect(error.details).to eq('team_id' => ['is inherited from deal'])
    end
    expect(task.reload.team).to eq(deal_team)
  end

  it 'repairs a stale linked task team on its next update' do
    stale_team = create(:team, account: account)
    task = create(:crm_task, account: account, deal: deal, status: status, team: stale_team)

    updated_task = described_class.new(
      account: account,
      task: task,
      params: {
        lock_version: task.lock_version,
        title: 'Updated proposal'
      }
    ).perform

    expect(updated_task.team).to eq(deal_team)
  end

  it 'clears an inherited team when a task is unlinked from its deal' do
    task = create(:crm_task, account: account, deal: deal, status: status, team: deal_team)

    updated_task = described_class.new(
      account: account,
      task: task,
      params: {
        context_kind: 'personal',
        deal_id: nil,
        lock_version: task.lock_version
      }
    ).perform

    expect(updated_task.deal).to be_nil
    expect(updated_task.team).to be_nil
    expect(updated_task.context_kind).to eq('personal')
  end

  it 'does not let a sales task lose its deal implicitly' do
    task = create(:crm_task, account: account, deal: deal, status: status, team: deal_team)

    request = lambda do
      described_class.new(
        account: account,
        task: task,
        params: { deal_id: nil, lock_version: task.lock_version }
      ).perform
    end

    expect(&request).to raise_error(Crm::Error) do |error|
      expect(error.details).to eq('deal_id' => ['is required for sales tasks'])
    end
    expect(task.reload).to have_attributes(context_kind: 'sales', deal_id: deal.id)
  end

  it 'keeps explicit team assignment available for standalone tasks' do
    standalone_team = create(:team, account: account)

    task = described_class.new(
      account: account,
      params: {
        status_id: status.id,
        team_id: standalone_team.id,
        title: 'Standalone follow-up'
      }
    ).perform

    expect(task.deal).to be_nil
    expect(task.team).to eq(standalone_team)
  end

  it 'resolves originating_conversation_display_id accurately even when primary key collides' do
    inbox = create(:inbox, account: account)
    contact = create(:contact, account: account)
    first_conv = create(:conversation, account: account, inbox: inbox, contact: contact)
    second_conv = create(:conversation, account: account, inbox: inbox, contact: contact)
    # rubocop:disable Rails/SkipsModelValidations
    first_conv.update_columns(display_id: first_conv.id + 50_000)
    second_conv.update_columns(display_id: first_conv.id)
    # rubocop:enable Rails/SkipsModelValidations

    task = described_class.new(
      account: account,
      params: {
        status_id: status.id,
        title: 'Task from conversation display_id',
        originating_conversation_display_id: second_conv.display_id,
        originating_conversation_id: second_conv.display_id
      }
    ).perform

    expect(task.originating_conversation).to eq(second_conv)
  end

  it 'falls back to conversation display_id when originating_conversation_id does not match a primary key' do
    inbox = create(:inbox, account: account)
    contact = create(:contact, account: account)
    conv = create(:conversation, account: account, inbox: inbox, contact: contact)
    # rubocop:disable Rails/SkipsModelValidations
    conv.update_columns(display_id: conv.id + 50_000)
    # rubocop:enable Rails/SkipsModelValidations

    task = described_class.new(
      account: account,
      params: {
        status_id: status.id,
        title: 'Legacy display_id in originating_conversation_id',
        originating_conversation_id: conv.display_id
      }
    ).perform

    expect(task.originating_conversation).to eq(conv)
  end

  it 'resolves originating_communication_thread_id to the latest thread conversation or nil when conversationless' do
    inbox = create(:inbox, account: account)
    contact = create(:contact, account: account)
    thread = CommunicationThread.create!(account: account, contact: contact, status: :open)
    conv = create(:conversation, account: account, inbox: inbox, contact: contact)
    CommunicationThreadConversation.find_or_create_by!(account: account, inbox: inbox, communication_thread: thread, conversation: conv)

    linked_task = described_class.new(
      account: account,
      params: {
        status_id: status.id,
        title: 'Task from communication thread',
        originating_communication_thread_id: thread.display_id
      }
    ).perform
    expect(linked_task.originating_conversation).to eq(conv)

    empty_contact = create(:contact, account: account)
    empty_thread = CommunicationThread.create!(account: account, contact: empty_contact, status: :open)
    standalone_task = described_class.new(
      account: account,
      params: {
        status_id: status.id,
        title: 'Task from call-only thread',
        originating_communication_thread_id: empty_thread.display_id
      }
    ).perform
    expect(standalone_task.originating_conversation).to be_nil
  end

  it 'preserves originating_conversation_display_id precedence in SaveFormService without PK collision' do
    actor = create(:user, account: account, role: :agent)
    task = described_class.new(account: account, actor: actor, params: { status_id: status.id, title: 'Initial task' }).perform
    decoy_conv = create(:conversation, account: account)
    target_conv = create(:conversation, account: account)
    target_conv.update!(display_id: decoy_conv.id)

    updated = Crm::Tasks::SaveFormService.new(
      account: account,
      task: task,
      actor: actor,
      params: {
        idempotency_key: "save-form-disp-#{SecureRandom.hex(4)}",
        lock_version: task.lock_version,
        originating_conversation_display_id: decoy_conv.id,
        originating_conversation_id: decoy_conv.id
      }
    ).perform

    expect(updated.originating_conversation).to eq(target_conv)
  end

  it 'skips historical conversation assignee removed from account.users when resolving default_assignee' do
    ex_agent = create(:user, account: account, role: :agent)
    conv = create(:conversation, account: account, assignee: ex_agent)
    AccountUser.where(account: account, user: ex_agent).delete_all

    task = described_class.new(
      account: account,
      params: {
        status_id: status.id,
        title: 'Task after assignee removal',
        originating_conversation_display_id: conv.display_id
      }
    ).perform

    expect(task).to be_persisted
    expect(task.assignee).to be_nil
  end
end
