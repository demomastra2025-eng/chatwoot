require 'rails_helper'

RSpec.describe AutomationRules::CrmConditionService do
  let(:account) { create(:account) }

  describe 'deal conditions' do
    let(:pipeline) { create(:crm_pipeline, account: account) }
    let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
    let(:deal) do
      create(
        :crm_deal,
        account: account,
        pipeline: pipeline,
        stage: stage,
        amount_minor: 25_000,
        currency: 'USD',
        custom_attributes: { 'deal_region' => 'emea' }
      )
    end

    before do
      account.enable_features!('crm_deals')
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'deal',
        key: 'deal_region',
        label: 'Deal region',
        field_type: 'select',
        options: [{ 'label' => 'EMEA', 'value' => 'emea' }]
      )
    end

    it 'matches standard and managed custom deal conditions' do
      rule = create(
        :automation_rule,
        account: account,
        event_name: 'deal_updated',
        conditions: [
          {
            attribute_key: 'amount_minor',
            filter_operator: 'is_greater_than',
            values: ['10000'],
            query_operator: 'AND'
          },
          {
            attribute_key: 'deal_region',
            filter_operator: 'equal_to',
            values: ['emea'],
            query_operator: nil,
            custom_attribute_type: 'deal_attribute'
          }
        ],
        actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/deals'] }]
      )

      result = described_class.new(rule, deal, entity_kind: 'deal').perform
      expect(result).to be(true)
    end
  end

  describe 'task conditions' do
    let(:status) { create(:crm_task_status, account: account, code: 'todo', category: 'open') }
    let(:task) do
      create(
        :crm_task,
        account: account,
        status: status,
        due_at: Time.zone.parse('2026-04-02 10:00:00'),
        custom_attributes: { 'task_channel' => 'chat' }
      )
    end

    before do
      account.enable_features!('crm_tasks')
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'task',
        key: 'task_channel',
        label: 'Task channel',
        field_type: 'select',
        options: [{ 'label' => 'Chat', 'value' => 'chat' }]
      )
    end

    it 'matches standard and managed custom task conditions' do
      rule = create(
        :automation_rule,
        account: account,
        event_name: 'task_updated',
        conditions: [
          {
            attribute_key: 'due_at',
            filter_operator: 'is_greater_than',
            values: ['2026-04-01T00:00:00Z'],
            query_operator: 'AND'
          },
          {
            attribute_key: 'task_channel',
            filter_operator: 'equal_to',
            values: ['chat'],
            query_operator: nil,
            custom_attribute_type: 'task_attribute'
          }
        ],
        actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/tasks'] }]
      )

      result = described_class.new(rule, task, entity_kind: 'task').perform
      expect(result).to be(true)
    end
  end
end
