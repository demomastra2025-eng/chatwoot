require 'rails_helper'
require 'rake'

RSpec.describe Reminders::ConvertPlanActionsService do
  let(:account) { create(:account) }
  let(:steps) do
    [
      { body: 'First reminder', delay_minutes: 10, action_type: 'send_message' },
      { body: 'Second reminder', delay_minutes: 60, action_type: 'send_message' }
    ]
  end
  let(:group) { create(:reminder_group, account: account, entity_kinds: ['conversation'], touches: steps) }
  let(:rule) do
    actions = [
      { action_name: 'apply_touch_plan', action_id: 'legacy-action', action_params: [group.id] },
      { action_name: 'add_label', action_id: 'other-action', action_params: ['follow-up'] }
    ]
    build(:automation_rule, account: account, actions: actions).tap { |record| record.save!(validate: false) }
  end
  let(:task) { Rake::Task['reminders:convert_plan_actions'] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('reminders:convert_plan_actions')
    rule
    task.reenable
  end

  it 'reports changes without writing by default' do
    expect { with_modified_env('APPLY' => nil) { task.invoke } }
      .to output(/mode=dry-run account=#{account.id} rule=#{rule.id} apply_touch_plan=legacy-action -> create_touch_actions=2/).to_stdout
    expect(rule.reload.actions.pluck('action_name')).to eq(%w[apply_touch_plan add_label])
  end

  it 'converts every step once and preserves other actions and step fields' do
    with_modified_env('APPLY' => '1') { task.invoke }

    actions = rule.reload.actions
    expect(actions.pluck('action_name')).to eq(%w[create_touch create_touch add_label])
    expect(actions.first(2).map { |action| action['action_params'].first['body'] }).to eq(steps.pluck(:body))
    expect(actions.first(2).map { |action| action['action_params'].first['delay_minutes'] }).to eq([10, 60])
    expect(actions.first(2).map { |action| action['action_params'].first }).to all(satisfy { |step| !step.key?('step_id') })
    expect(actions.last['action_id']).to eq('other-action')

    task.reenable
    with_modified_env('APPLY' => '1') { task.invoke }
    expect(rule.reload.actions).to eq(actions)
  end

  it 'retains an unchanged plan-scoped cancellation beside converted actions' do
    rule.actions = rule.actions + [
      { action_name: 'cancel_touches', action_params: [{ reminder_group_id: group.id }] }
    ]
    rule.save!(validate: false)

    with_modified_env('APPLY' => '1') { task.invoke }

    expect(rule.reload.actions.pluck('action_name')).to eq(%w[create_touch create_touch add_label cancel_touches])
    expect(rule.actions.last['action_params']).to eq([{ 'reminder_group_id' => group.id }])
  end

  it 'leaves a rule unchanged when its plan is archived' do
    group.archive!
    original_actions = rule.reload.actions

    with_modified_env('APPLY' => '1') { task.invoke }

    expect(rule.reload.actions).to eq(original_actions)
  end

  it 'does not update a rule without a plan action' do
    unrelated = create(:automation_rule, account: account)
    original_actions = unrelated.actions
    original_updated_at = unrelated.updated_at

    with_modified_env('APPLY' => '1') { task.invoke }

    expect(unrelated.reload.actions).to eq(original_actions)
    expect(unrelated.updated_at).to eq(original_updated_at)
  end
end
