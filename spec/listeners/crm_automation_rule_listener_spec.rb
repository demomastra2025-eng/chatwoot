require 'rails_helper'

RSpec.describe CrmAutomationRuleListener do
  let(:listener) { described_class.instance }
  let(:account) { create(:account) }

  describe 'deal automation' do
    let(:pipeline) { create(:crm_pipeline, account: account) }
    let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
    let(:deal) { create(:crm_deal, account: account, pipeline: pipeline, stage: stage, title: 'Renewal opportunity') }
    let(:owner) do
      user = create(:user)
      create(:account_user, account: account, user: user)
      user
    end
    let(:team) { create(:team, account: account) }

    before do
      account.enable_features!('crm_deals')
      clear_enqueued_jobs
      clear_performed_jobs
    end

    it 'applies native deal actions after CRM event dispatch' do
      create(
        :automation_rule,
        account: account,
        event_name: 'deal_updated',
        conditions: [{ attribute_key: 'title', filter_operator: 'contains', values: ['Renewal'], query_operator: nil }],
        actions: [{ action_name: 'assign_deal_owner', action_params: [owner.id] }]
      )

      perform_enqueued_jobs do
        Crm::Deals::UpsertService.new(
          account: account,
          deal: deal,
          params: { title: 'Renewal opportunity updated', lock_version: deal.lock_version },
          actor: nil
        ).perform
      end

      expect(deal.reload.owner_id).to eq(owner.id)
    end

    it 'evaluates deal rules against a stable snapshot within the same event pass' do
      create(
        :automation_rule,
        account: account,
        event_name: 'deal_updated',
        conditions: [{ attribute_key: 'title', filter_operator: 'contains', values: ['Renewal'], query_operator: nil }],
        actions: [{ action_name: 'assign_deal_owner', action_params: [owner.id] }]
      )
      create(
        :automation_rule,
        account: account,
        event_name: 'deal_updated',
        conditions: [{ attribute_key: 'owner_id', filter_operator: 'equal_to', values: [owner.id.to_s], query_operator: nil }],
        actions: [{ action_name: 'assign_deal_team', action_params: [team.id] }]
      )

      listener.deal_updated(
        Events::Base.new(
          'deal_updated',
          Time.zone.now,
          deal: deal,
          changed_attributes: { 'title' => ['Old', 'Renewal opportunity updated'] },
          automation_matching_snapshot: AutomationRules::CrmMatchingSnapshot.build(deal)
        )
      )

      deal.reload
      expect(deal.owner_id).to eq(owner.id)
      expect(deal.team_id).to be_nil
    end
  end

  describe 'task automation' do
    let(:status) { create(:crm_task_status, account: account, code: 'todo', category: 'open') }
    let(:task) { create(:crm_task, account: account, status: status, title: 'Follow up') }
    let(:assignee) do
      user = create(:user)
      create(:account_user, account: account, user: user)
      user
    end

    before do
      account.enable_features!('crm_tasks')
      clear_enqueued_jobs
      clear_performed_jobs
    end

    it 'runs legacy status-change rules once for granular task completion events' do
      create(
        :automation_rule,
        account: account,
        event_name: 'task_status_changed',
        conditions: [],
        actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/tasks'] }]
      )
      event = Events::Base.new(
        'task_completed',
        Time.zone.now,
        account: account,
        task: task,
        changed_attributes: { 'status_id' => [status.id, status.id + 1] },
        automation_matching_snapshot: AutomationRules::CrmMatchingSnapshot.build(task)
      )

      expect do
        listener.task_completed(event)
      end.to have_enqueued_job(WebhookJob).with(
        'https://example.com/hooks/tasks',
        hash_including(event: 'automation_event.task_status_changed')
      ).once
    end

    it 'applies native task actions after CRM event dispatch' do
      create(
        :automation_rule,
        account: account,
        event_name: 'task_updated',
        conditions: [{ attribute_key: 'title', filter_operator: 'contains', values: ['Follow'], query_operator: nil }],
        actions: [{ action_name: 'assign_task_assignee', action_params: [assignee.id] }]
      )

      perform_enqueued_jobs do
        Crm::Tasks::UpsertService.new(
          account: account,
          task: task,
          params: { title: 'Follow up with client today', lock_version: task.lock_version },
          actor: nil
        ).perform
      end

      expect(task.reload.assignee_id).to eq(assignee.id)
    end
  end
end
