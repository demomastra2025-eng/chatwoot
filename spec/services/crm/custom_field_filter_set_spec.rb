require 'rails_helper'

RSpec.describe Crm::CustomFieldFilterSet do
  let(:account) { create(:account) }

  before do
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  describe 'deal filters' do
    let!(:pipeline) do
      create(
        :crm_pipeline,
        account: account,
        code: 'sales_pipeline',
        default: true
      )
    end
    let!(:stage) do
      create(
        :crm_stage,
        account: account,
        pipeline: pipeline,
        code: 'new',
        position: 1
      )
    end

    let!(:status_definition) do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'deal',
        key: 'deal_status_code',
        label: 'Deal status',
        field_type: 'select',
        options: [{ 'label' => 'Qualified', 'value' => 'qualified' }]
      )
    end

    let!(:budget_definition) do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'deal',
        key: 'budget_score',
        label: 'Budget score',
        field_type: 'number'
      )
    end

    let!(:follow_up_definition) do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'deal',
        key: 'follow_up_on',
        label: 'Follow up on',
        field_type: 'date'
      )
    end

    let!(:matching_deal) do
      create(
        :crm_deal,
        account: account,
        pipeline: pipeline,
        stage: stage,
        custom_attributes: {
          'budget_score' => 92,
          'deal_status_code' => 'qualified',
          'follow_up_on' => '2026-04-05'
        }
      )
    end

    let!(:other_deal) do
      create(
        :crm_deal,
        account: account,
        pipeline: pipeline,
        stage: stage,
        custom_attributes: {
          'budget_score' => 44,
          'deal_status_code' => 'cold',
          'follow_up_on' => '2026-04-10'
        }
      )
    end

    it 'matches deal records by discrete and advanced filters' do
      filter_set = described_class.new(
        account: account,
        entity_kind: 'deal',
        raw_filters: {
          budget_score: { operator: 'greater_than', value: 60 },
          deal_status_code: ['qualified'],
          follow_up_on: { operator: 'before', value: '2026-04-06' }
        }
      )

      expect(filter_set.apply([matching_deal, other_deal])).to contain_exactly(matching_deal)
    end

    it 'filters an ActiveRecord relation for deal records' do
      filter_set = described_class.new(
        account: account,
        entity_kind: 'deal',
        raw_filters: {
          budget_score: { operator: 'greater_than', value: 60 },
          deal_status_code: ['qualified']
        }
      )

      expect(filter_set.apply(account.crm_deals.ordered)).to contain_exactly(matching_deal)
    end

    it 'ignores malformed numeric values when filtering an ActiveRecord relation' do
      other_deal.update!(custom_attributes: other_deal.custom_attributes.merge('budget_score' => 'not-a-number'))
      filter_set = described_class.new(
        account: account,
        entity_kind: 'deal',
        raw_filters: {
          budget_score: { operator: 'greater_than', value: 60 }
        }
      )

      expect { filter_set.apply(account.crm_deals.ordered).to_a }.not_to raise_error
      expect(filter_set.apply(account.crm_deals.ordered)).to contain_exactly(matching_deal)
    end
  end

  describe 'task filters' do
    let!(:open_status) do
      create(
        :crm_task_status,
        account: account,
        code: 'todo',
        category: 'open',
        default: true
      )
    end

    let!(:tag_definition) do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'task',
        key: 'task_tags',
        label: 'Task tags',
        field_type: 'multiselect',
        options: ['VIP', 'Docs']
      )
    end

    let!(:note_definition) do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'task',
        key: 'resolution_note',
        label: 'Resolution note',
        field_type: 'text'
      )
    end

    let!(:matching_task) do
      create(
        :crm_task,
        account: account,
        status: open_status,
        custom_attributes: {
          'resolution_note' => 'Needs urgent documents',
          'task_tags' => ['VIP']
        }
      )
    end

    let!(:other_task) do
      create(
        :crm_task,
        account: account,
        status: open_status,
        custom_attributes: {
          'resolution_note' => 'Regular follow-up',
          'task_tags' => ['Docs']
        }
      )
    end

    it 'ignores stale task filters and keeps valid matches' do
      filter_set = described_class.new(
        account: account,
        entity_kind: 'task',
        raw_filters: {
          resolution_note: { operator: 'contains', value: 'urgent' },
          task_tags: ['VIP', 'unknown'],
          unknown_key: ['value']
        }
      )

      expect(filter_set.apply([matching_task, other_task])).to contain_exactly(matching_task)
    end
  end
end
