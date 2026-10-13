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

  describe 'contact conditions' do
    let(:deal) { create(:crm_deal, account: account, title: 'Visit plan') }
    let(:contact) { create(:contact, account: account) }
    let(:other_contact) { create(:contact, account: account) }
    let(:task) { create(:crm_task, account: account, deal: deal, title: 'Call back') }

    before { account.enable_features!('crm_deals', 'crm_tasks') }

    def contact_condition(operator, ids, query_operator = nil)
      { attribute_key: 'contact_id', filter_operator: operator, values: ids, query_operator: query_operator }
    end

    def title_condition(value, query_operator = nil)
      { attribute_key: 'title', filter_operator: 'contains', values: [value], query_operator: query_operator }
    end

    def deal_rule(conditions)
      create(:automation_rule, account: account, event_name: 'deal_updated', conditions: conditions,
                               actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/deals'] }])
    end

    def task_rule(conditions)
      create(:automation_rule, account: account, event_name: 'task_updated', conditions: conditions,
                               actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/tasks'] }])
    end

    def deal_matches?(rule, options = {})
      described_class.new(rule, deal, entity_kind: 'deal', options: options).perform
    end

    def task_matches?(rule)
      described_class.new(rule, task, entity_kind: 'task').perform
    end

    context 'with a deal' do
      before do
        create(:crm_deal_contact, deal: deal, contact: contact, primary: true)
        create(:crm_deal_contact, deal: deal, contact: other_contact)
      end

      it 'skips the deal when any of its contacts is on an "is not" list' do
        expect(deal_matches?(deal_rule([contact_condition('not_equal_to', [other_contact.id])]))).to be(false)
        expect(deal_matches?(deal_rule([contact_condition('not_equal_to', [contact.id.to_s])]))).to be(false)
      end

      it 'matches the deal when none of its contacts is listed' do
        stranger = create(:contact, account: account)

        expect(deal_matches?(deal_rule([contact_condition('not_equal_to', [stranger.id])]))).to be(true)
      end

      it 'limits an "is" list to deals with a listed contact' do
        stranger = create(:contact, account: account)

        expect(deal_matches?(deal_rule([contact_condition('equal_to', [contact.id])]))).to be(true)
        expect(deal_matches?(deal_rule([contact_condition('equal_to', [stranger.id])]))).to be(false)
      end

      it 'combines with the other conditions through AND and OR' do
        listed = contact_condition('not_equal_to', [contact.id])

        expect(deal_matches?(deal_rule([title_condition('Visit', 'AND'), listed]))).to be(false)
        expect(deal_matches?(deal_rule([title_condition('Visit', 'OR'), listed]))).to be(true)
        expect(deal_matches?(deal_rule([listed.merge(query_operator: 'OR'), title_condition('Nothing')]))).to be(false)
      end

      it 'never matches an unreadable list or an unsupported operator' do
        rule = deal_rule([contact_condition('not_equal_to', [contact.id])])
        rule.update_columns(conditions: [contact_condition('not_equal_to', ['x']).stringify_keys]) # rubocop:disable Rails/SkipsModelValidations

        expect(deal_matches?(rule)).to be(false)
      end

      it 'reads the contacts the event fired with, not the ones the deal has afterwards' do
        snapshot = AutomationRules::CrmMatchingSnapshot.build(deal)[:matcher_data]['deal']
        Crm::DealContact.where(deal: deal).delete_all
        rule = deal_rule([contact_condition('not_equal_to', [contact.id])])

        expect(snapshot['contact_id']).to contain_exactly(contact.id, other_contact.id)
        expect(deal_matches?(rule, snapshot: snapshot)).to be(false)
        expect(deal_matches?(rule)).to be(true)
      end

      it 'falls back to the current contacts for an event recorded without them' do
        snapshot = AutomationRules::CrmMatchingSnapshot.build(deal)[:matcher_data]['deal'].except('contact_id')

        expect(deal_matches?(deal_rule([contact_condition('not_equal_to', [contact.id])]), snapshot: snapshot)).to be(false)
      end
    end

    context 'with a deal without contacts' do
      it 'matches "is not" and never "is"' do
        expect(deal_matches?(deal_rule([contact_condition('not_equal_to', [contact.id])]))).to be(true)
        expect(deal_matches?(deal_rule([contact_condition('equal_to', [contact.id])]))).to be(false)
      end
    end

    context 'with a task' do
      before { create(:crm_deal_contact, deal: deal, contact: contact, primary: true) }

      it 'reads the contacts of the deal of the task' do
        expect(task_matches?(task_rule([contact_condition('not_equal_to', [contact.id])]))).to be(false)
        expect(task_matches?(task_rule([contact_condition('equal_to', [contact.id])]))).to be(true)
        expect(task_matches?(task_rule([contact_condition('not_equal_to', [other_contact.id])]))).to be(true)
      end

      it 'combines with the other conditions' do
        listed = contact_condition('not_equal_to', [contact.id])

        expect(task_matches?(task_rule([title_condition('Call', 'AND'), listed]))).to be(false)
        expect(task_matches?(task_rule([title_condition('Call', 'OR'), listed]))).to be(true)
      end

      it 'treats a task without a deal as having no contact' do
        task.update_columns(deal_id: nil) # rubocop:disable Rails/SkipsModelValidations
        task.reload

        expect(task_matches?(task_rule([contact_condition('not_equal_to', [contact.id])]))).to be(true)
        expect(task_matches?(task_rule([contact_condition('equal_to', [contact.id])]))).to be(false)
      end
    end

    it 'writes the contacts of the deal and of its task into the matching snapshot' do
      create(:crm_deal_contact, deal: deal, contact: contact, primary: true)

      deal_snapshot = AutomationRules::CrmMatchingSnapshot.build(deal)
      task_snapshot = AutomationRules::CrmMatchingSnapshot.build(task)

      expect(deal_snapshot.dig(:matcher_data, 'deal', 'contact_id')).to eq([contact.id])
      expect(task_snapshot.dig(:matcher_data, 'task', 'contact_id')).to eq([contact.id])
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

    it 'matches legacy task rules with no conditions' do
      rule = create(:automation_rule, account: account, event_name: 'task_status_changed', conditions: [], actions: [])

      expect(described_class.new(rule, task, entity_kind: 'task').perform).to be(true)
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
