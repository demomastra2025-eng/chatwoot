require 'rails_helper'

RSpec.describe AutomationRules::CrmActionService do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }

  describe 'deal actions' do
    let(:pipeline) { create(:crm_pipeline, account: account) }
    let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
    let(:next_stage) do
      create(
        :crm_stage,
        account: account,
        pipeline: pipeline,
        name: 'Won',
        outcome: 'won',
        color: '#16a34a'
      )
    end
    let(:owner) do
      user = create(:user)
      create(:account_user, account: account, user: user)
      user
    end
    let(:deal) { create(:crm_deal, account: account, pipeline: pipeline, stage: stage) }
    let(:rule) do
      create(
        :automation_rule,
        account: account,
        event_name: 'deal_updated',
        conditions: [{ attribute_key: 'stage_id', filter_operator: 'equal_to', values: [stage.id.to_s], query_operator: nil }],
        actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/deals'] }]
      )
    end

    before do
      account.enable_features!('crm_deals')
    end

    it 'enqueues a webhook with deal payload and changed attributes' do
      service = described_class.new(
        rule,
        account,
        deal,
        entity_kind: 'deal',
        options: { changed_attributes: { 'title' => ['Old title', 'New title'] } }
      )

      expect do
        service.perform
      end.to have_enqueued_job(WebhookJob).with(
        'https://example.com/hooks/deals',
        hash_including(
          event: 'automation_event.deal_updated',
          deal: hash_including(id: deal.id, title: deal.title),
          changed_attributes: [{ 'title' => { previous_value: 'Old title', current_value: 'New title' } }]
        )
      )
    end

    it 'updates deal stage through the native transition path' do
      status_rule = create(
        :automation_rule,
        account: account,
        event_name: 'deal_updated',
        conditions: [{ attribute_key: 'stage_id', filter_operator: 'equal_to', values: [stage.id.to_s], query_operator: nil }],
        actions: [{ action_name: 'change_deal_stage', action_params: [next_stage.id] }]
      )

      described_class.new(status_rule, account, deal, entity_kind: 'deal').perform

      expect(deal.reload.stage_id).to eq(next_stage.id)
    end

    it 'assigns deal owner through the native upsert path' do
      owner_rule = create(
        :automation_rule,
        account: account,
        event_name: 'deal_updated',
        conditions: [{ attribute_key: 'stage_id', filter_operator: 'equal_to', values: [stage.id.to_s], query_operator: nil }],
        actions: [{ action_name: 'assign_deal_owner', action_params: [owner.id] }]
      )

      described_class.new(owner_rule, account, deal, entity_kind: 'deal').perform

      expect(deal.reload.owner_id).to eq(owner.id)
    end
  end

  describe 'task actions' do
    let(:open_status) { create(:crm_task_status, account: account, code: 'todo', category: 'open') }
    let(:done_status) do
      create(
        :crm_task_status,
        account: account,
        code: 'done',
        category: 'done',
        color: Crm::TaskStatus::STANDARD_COLORS.second
      )
    end
    let(:assignee) do
      user = create(:user)
      create(:account_user, account: account, user: user)
      user
    end
    let(:task) { create(:crm_task, account: account, status: open_status) }

    before do
      account.enable_features!('crm_tasks')
    end

    it 'updates task status through the native transition path' do
      rule = create(
        :automation_rule,
        account: account,
        event_name: 'task_updated',
        conditions: [{ attribute_key: 'status_id', filter_operator: 'equal_to', values: [open_status.id.to_s], query_operator: nil }],
        actions: [{ action_name: 'change_task_status', action_params: [done_status.id] }]
      )

      described_class.new(rule, account, task, entity_kind: 'task').perform

      expect(task.reload.status_id).to eq(done_status.id)
      expect(task.completed_at).to be_present
    end

    it 'assigns task assignee through the native upsert path' do
      rule = create(
        :automation_rule,
        account: account,
        event_name: 'task_updated',
        conditions: [{ attribute_key: 'status_id', filter_operator: 'equal_to', values: [open_status.id.to_s], query_operator: nil }],
        actions: [{ action_name: 'assign_task_assignee', action_params: [assignee.id] }]
      )

      described_class.new(rule, account, task, entity_kind: 'task').perform

      expect(task.reload.assignee_id).to eq(assignee.id)
    end
  end
end
