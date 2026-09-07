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
end
