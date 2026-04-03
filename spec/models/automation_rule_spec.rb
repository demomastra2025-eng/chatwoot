require 'rails_helper'
require Rails.root.join 'spec/models/concerns/reauthorizable_shared.rb'

RSpec.describe AutomationRule do
  describe 'concerns' do
    it_behaves_like 'reauthorizable'
  end

  describe 'associations' do
    let(:account) { create(:account) }
    let(:params) do
      {
        name: 'Notify Conversation Created and mark priority query',
        description: 'Notify all administrator about conversation created and mark priority query',
        event_name: 'conversation_created',
        account_id: account.id,
        conditions: [
          {
            attribute_key: 'browser_language',
            filter_operator: 'equal_to',
            values: ['en'],
            query_operator: 'AND'
          },
          {
            attribute_key: 'country_code',
            filter_operator: 'equal_to',
            values: %w[USA UK],
            query_operator: nil
          }
        ],
        actions: [
          {
            action_name: :send_message,
            action_params: ['Welcome to the chatwoot platform.']
          },
          {
            action_name: :assign_team,
            action_params: [1]
          },
          {
            action_name: :add_label,
            action_params: %w[support priority_customer]
          },
          {
            action_name: :assign_agent,
            action_params: [1]
          }
        ]
      }.with_indifferent_access
    end

    it 'returns valid record' do
      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'returns invalid record' do
      params[:conditions][0].delete('query_operator')
      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:conditions]).to eq(['Automation conditions should have query operator.'])
    end

    it 'allows labels as a valid condition attribute' do
      params[:conditions] = [
        {
          attribute_key: 'labels',
          filter_operator: 'equal_to',
          values: ['bug'],
          query_operator: nil
        }
      ]
      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'validates label condition operators' do
      params[:conditions] = [
        {
          attribute_key: 'labels',
          filter_operator: 'is_present',
          values: [],
          query_operator: nil
        }
      ]
      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'allows appointment automation rules with supported conditions and webhook action' do
      account.enable_features!('scheduling')
      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'payment_status',
          filter_operator: 'equal_to',
          values: ['paid'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :send_webhook_event,
          action_params: ['https://example.com/hooks/appointments']
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'allows appointment automation rules with native status change action' do
      account.enable_features!('scheduling')
      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['scheduled'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :change_appointment_status,
          action_params: ['confirmed']
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'allows appointment automation rules with active managed custom fields' do
      account.enable_features!('scheduling')
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'appointment',
        key: 'visit_reason',
        label: 'Visit reason',
        field_type: 'select',
        options: [{ 'label' => 'Follow-up', 'value' => 'follow_up' }]
      )

      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'visit_reason',
          filter_operator: 'equal_to',
          values: ['follow_up'],
          query_operator: nil,
          custom_attribute_type: 'appointment_attribute'
        }
      ]
      params[:actions] = [
        {
          action_name: :send_webhook_event,
          action_params: ['https://example.com/hooks/appointments']
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'rejects unsupported appointment automation actions' do
      account.enable_features!('scheduling')
      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['scheduled'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :assign_agent,
          action_params: [1]
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:actions]).to eq(['Automation actions assign_agent not supported.'])
    end

    it 'rejects appointment status change actions with unsupported target statuses' do
      account.enable_features!('scheduling')
      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['scheduled'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :change_appointment_status,
          action_params: ['archived']
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:actions]).to eq(
        ['Automation action parameters change_appointment_status not supported.']
      )
    end

    it 'rejects appointment payment cancellation actions when scheduling finance is disabled' do
      account.enable_features!('scheduling')
      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['scheduled'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :cancel_appointment_payment,
          action_params: []
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:actions]).to eq(['Automation actions cancel_appointment_payment not supported.'])
    end

    it 'allows appointment payment cancellation actions when scheduling finance is enabled' do
      account.enable_features!('scheduling')
      account.enable_features!('scheduling_finance')
      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['scheduled'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :cancel_appointment_payment,
          action_params: []
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'rejects unsupported appointment automation conditions' do
      account.enable_features!('scheduling')
      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'inbox_id',
          filter_operator: 'equal_to',
          values: ['1'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :send_webhook_event,
          action_params: ['https://example.com/hooks/appointments']
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:conditions]).to eq(['Automation conditions inbox_id not supported.'])
    end

    it 'rejects unsupported appointment automation operators for managed fields' do
      account.enable_features!('scheduling')
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'appointment',
        key: 'visit_reason',
        label: 'Visit reason',
        field_type: 'select',
        options: [{ 'label' => 'Follow-up', 'value' => 'follow_up' }]
      )

      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'visit_reason',
          filter_operator: 'contains',
          values: ['follow_up'],
          query_operator: nil,
          custom_attribute_type: 'appointment_attribute'
        }
      ]
      params[:actions] = [
        {
          action_name: :send_webhook_event,
          action_params: ['https://example.com/hooks/appointments']
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:conditions]).to eq(
        ['Automation condition operators visit_reason:contains not supported.']
      )
    end

    it 'rejects unsupported automation events' do
      params[:event_name] = 'unsupported_event'

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:event_name]).to eq(['Automation event not supported.'])
    end

    it 'rejects appointment automation events when scheduling is disabled' do
      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'status',
          filter_operator: 'equal_to',
          values: ['scheduled'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :send_webhook_event,
          action_params: ['https://example.com/hooks/appointments']
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:event_name]).to eq(['Automation event requires scheduling feature.'])
    end

    it 'allows deal automation rules with supported native actions and managed custom fields' do
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
      pipeline = create(:crm_pipeline, account: account)
      stage = create(:crm_stage, account: account, pipeline: pipeline)
      owner = create(:user)
      create(:account_user, account: account, user: owner)

      params[:event_name] = 'deal_created'
      params[:conditions] = [
        {
          attribute_key: 'deal_region',
          filter_operator: 'equal_to',
          values: ['emea'],
          query_operator: nil,
          custom_attribute_type: 'deal_attribute'
        }
      ]
      params[:actions] = [
        {
          action_name: :change_deal_stage,
          action_params: [stage.id]
        },
        {
          action_name: :assign_deal_owner,
          action_params: [owner.id]
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'rejects deal automation events when crm deals is disabled' do
      params[:event_name] = 'deal_created'
      params[:conditions] = [
        {
          attribute_key: 'stage_id',
          filter_operator: 'equal_to',
          values: ['1'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :send_webhook_event,
          action_params: ['https://example.com/hooks/deals']
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:event_name]).to eq(['Automation event requires crm_deals feature.'])
    end

    it 'allows task automation rules with supported native actions and managed custom fields' do
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
      task_status = create(:crm_task_status, account: account)
      assignee = create(:user)
      create(:account_user, account: account, user: assignee)

      params[:event_name] = 'task_created'
      params[:conditions] = [
        {
          attribute_key: 'task_channel',
          filter_operator: 'equal_to',
          values: ['chat'],
          query_operator: nil,
          custom_attribute_type: 'task_attribute'
        }
      ]
      params[:actions] = [
        {
          action_name: :change_task_status,
          action_params: [task_status.id]
        },
        {
          action_name: :assign_task_assignee,
          action_params: [assignee.id]
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'rejects task automation events when crm tasks is disabled' do
      params[:event_name] = 'task_created'
      params[:conditions] = [
        {
          attribute_key: 'status_id',
          filter_operator: 'equal_to',
          values: ['1'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :send_webhook_event,
          action_params: ['https://example.com/hooks/tasks']
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:event_name]).to eq(['Automation event requires crm_tasks feature.'])
    end

    it 'rejects unsupported deal and task automation actions' do
      params[:conditions] = [
        {
          attribute_key: 'stage_id',
          filter_operator: 'equal_to',
          values: ['1'],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :assign_agent,
          action_params: [1]
        }
      ]

      params[:event_name] = 'deal_created'
      deal_rule = FactoryBot.build(:automation_rule, params)
      expect(deal_rule.valid?).to be false
      expect(deal_rule.errors.messages[:actions]).to eq(['Automation actions assign_agent not supported.'])

      params[:event_name] = 'task_created'
      task_rule = FactoryBot.build(:automation_rule, params)
      expect(task_rule.valid?).to be false
      expect(task_rule.errors.messages[:actions]).to eq(['Automation actions assign_agent not supported.'])
    end
  end

  describe 'reauthorizable' do
    context 'when prompt_reauthorization!' do
      it 'marks the rule inactive' do
        rule = create(:automation_rule)
        expect(rule.active).to be true
        rule.prompt_reauthorization!
        expect(rule.active).to be false
      end
    end

    context 'when reauthorization_required?' do
      it 'unsets the error count if conditions are updated' do
        rule = create(:automation_rule)
        rule.prompt_reauthorization!
        expect(rule.reauthorization_required?).to be true

        rule.update!(conditions: [{ attribute_key: 'browser_language', filter_operator: 'equal_to', values: ['en'], query_operator: 'AND' }])
        expect(rule.reauthorization_required?).to be false
      end

      it 'will not unset the error count if conditions are not updated' do
        rule = create(:automation_rule)
        rule.prompt_reauthorization!
        expect(rule.reauthorization_required?).to be true

        rule.update!(name: 'Updated name')
        expect(rule.reauthorization_required?).to be true
      end
    end
  end
end
