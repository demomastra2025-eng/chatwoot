require 'rails_helper'
require Rails.root.join 'spec/models/concerns/reauthorizable_shared.rb'

RSpec.describe AutomationRule do
  describe 'action identity' do
    it 'preserves omitted action ids on update and deduplicates client-provided ids' do
      rule = create(
        :automation_rule,
        actions: [{ action_name: 'create_touch', action_params: { body: 'Initial', delay_minutes: 5 } }]
      )
      original_action = rule.actions.first
      original_action_id = original_action['action_id']

      updated_params = original_action['action_params'].merge('body' => 'Updated')
      rule.update!(actions: [original_action.except('action_id').merge('action_params' => updated_params)])
      expect(rule.reload.actions.first['action_id']).to eq(original_action_id)

      rule.update!(actions: [rule.actions.first, rule.actions.first])
      expect(rule.reload.actions.pluck('action_id').uniq.size).to eq(2)
    end

    it 'assigns distinct stable ids to multiple send_message actions' do
      rule = create(
        :automation_rule,
        actions: [
          { action_name: 'send_message', action_params: ['First'] },
          { action_name: 'send_message', action_params: ['Second'] }
        ]
      )
      action_ids = rule.actions.pluck('action_id')

      expect(action_ids.compact.uniq.size).to eq(2)
      rule.update!(actions: rule.actions.map { |action| action.except('action_id') })
      expect(rule.reload.actions.pluck('action_id')).to eq(action_ids)
    end
  end

  describe 'execution schedule validation' do
    let(:account) { create(:account) }

    it 'accepts a relative anchor supported by the rule event' do
      rule = build(
        :automation_rule,
        account: account,
        event_name: 'conversation_created',
        execution_schedule: {
          timing_mode: 'relative',
          relative_anchor: 'conversation.created_at',
          relative_offset_seconds: 3600,
          timezone: 'UTC'
        }
      )

      expect(rule).to be_valid
    end

    it 'rejects an invalid timezone, relative anchor and offset' do
      rule = build(
        :automation_rule,
        account: account,
        event_name: 'conversation_created',
        execution_schedule: {
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: 'later',
          timezone: 'Mars/Olympus'
        }
      )

      expect(rule).not_to be_valid
      expect(rule.errors[:execution_schedule]).to include(
        'timezone is invalid',
        'relative anchor is not supported for this event',
        'relative offset seconds must be an integer'
      )
    end

    it 'rejects an absolute schedule without an ISO 8601 timestamp' do
      rule = build(
        :automation_rule,
        account: account,
        execution_schedule: { timing_mode: 'absolute', scheduled_at: 'tomorrow' }
      )

      expect(rule).not_to be_valid
      expect(rule.errors[:execution_schedule]).to include('scheduled_at must be an ISO 8601 timestamp')
    end

    it 'rejects fields that are incompatible with the timing mode' do
      rule = build(
        :automation_rule,
        account: account,
        execution_schedule: {
          timing_mode: 'absolute',
          scheduled_at: 1.day.from_now.iso8601,
          relative_anchor: 'conversation.created_at'
        }
      )

      expect(rule).not_to be_valid
      expect(rule.errors[:execution_schedule]).to include('absolute timing cannot include relative fields')
    end
  end

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
            action_name: :remove_assigned_agent
          },
          {
            action_name: :remove_assigned_team
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

    it 'allows conversation transferred to AI automation rules' do
      params[:event_name] = 'conversation_transferred_to_ai'

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'allows conversation automation rules to cancel all scheduled touches' do
      params[:actions] = [
        {
          action_name: :cancel_touches,
          action_params: []
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'rejects touch-plan filters for cancel_touches in new automation rules' do
      touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
      params[:actions] = [
        {
          action_name: :cancel_touches,
          action_params: [{ reminder_group_id: touch_plan.id }]
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)

      expect(rule).not_to be_valid
      expect(rule.errors[:actions]).to include(AutomationRule::LEGACY_TOUCH_PLAN_ACTION_ERROR)
    end

    it 'rejects touch-plan application in new automation rules' do
      touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
      params[:actions] = [
        {
          action_name: :apply_touch_plan,
          action_params: [touch_plan.id]
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)

      expect(rule).not_to be_valid
      expect(rule.errors[:actions]).to include(AutomationRule::LEGACY_TOUCH_PLAN_ACTION_ERROR)
    end

    it 'keeps an unchanged legacy touch-plan action executable but prevents changing it' do
      touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
      other_touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
      params[:actions] = [
        {
          action_name: :apply_touch_plan,
          action_params: [touch_plan.id]
        }
      ]
      rule = FactoryBot.build(:automation_rule, params)
      rule.save!(validate: false)

      expect(rule.update(name: 'Renamed legacy automation')).to be(true)

      rule.event_name = 'conversation_updated'
      expect(rule).not_to be_valid
      expect(rule.errors[:actions]).to include(AutomationRule::LEGACY_TOUCH_PLAN_ACTION_ERROR)

      rule.reload
      rule.actions = [
        {
          action_name: :apply_touch_plan,
          action_params: [other_touch_plan.id]
        }
      ]

      expect(rule).not_to be_valid
      expect(rule.errors[:actions]).to include(AutomationRule::LEGACY_TOUCH_PLAN_ACTION_ERROR)
    end

    it 'keeps an unchanged legacy touch-plan cancellation executable but prevents changing it' do
      touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
      other_touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
      params[:actions] = [
        {
          action_name: :cancel_touches,
          action_params: [{ reminder_group_id: touch_plan.id }]
        }
      ]
      rule = FactoryBot.build(:automation_rule, params)
      rule.save!(validate: false)

      expect(rule.update(name: 'Renamed legacy cancellation')).to be(true)

      rule.actions = [
        {
          action_name: :cancel_touches,
          action_params: [{ reminder_group_id: other_touch_plan.id }]
        }
      ]

      expect(rule).not_to be_valid
      expect(rule.errors[:actions]).to include(AutomationRule::LEGACY_TOUCH_PLAN_ACTION_ERROR)
    end

    it 'allows explicit migration from a legacy touch plan to standalone touches' do
      touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
      params[:actions] = [{ action_name: :apply_touch_plan, action_params: [touch_plan.id] }]
      rule = FactoryBot.build(:automation_rule, params)
      rule.save!(validate: false)

      migrated_actions = [
        { action_name: :create_touch, action_params: [{ body: 'First follow-up', delay_minutes: 10 }] },
        { action_name: :create_touch, action_params: [{ body: 'Second follow-up', delay_minutes: 60 }] }
      ]

      expect(rule.update(actions: migrated_actions)).to be(true)
      expect(rule.reload.actions.pluck('action_name')).to eq(%w[create_touch create_touch])
    end

    it 'allows explicit migration from plan-scoped to plan-independent cancellation' do
      touch_plan = create(:reminder_group, account: account, entity_kinds: ['conversation'])
      params[:actions] = [
        { action_name: :cancel_touches, action_params: [{ reminder_group_id: touch_plan.id }] }
      ]
      rule = FactoryBot.build(:automation_rule, params)
      rule.save!(validate: false)

      expect(rule.update(actions: [{ action_name: :cancel_touches, action_params: [] }])).to be(true)
      expect(rule.reload.actions.first['action_params']).to eq([])
    end

    it 'allows full create_touch params with AI text and relative timing' do
      params[:actions] = [
        {
          action_name: :create_touch,
          action_params: {
            instructions: 'Generate a contextual AI follow-up',
            text_mode: 'agent',
            timing_mode: 'relative',
            relative_anchor: 'conversation.last_incoming_message_at',
            relative_offset_seconds: 3600,
            auto_cancel_on_incoming: true,
            timezone: 'Asia/Almaty'
          }
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'allows a safe post-delivery resolution on a one-time conversation touch' do
      params[:actions] = [
        {
          action_name: :create_touch,
          action_params: {
            body: 'Final follow-up',
            delay_minutes: 10,
            post_delivery_action: 'resolve_conversation'
          }
        }
      ]

      expect(FactoryBot.build(:automation_rule, params)).to be_valid
    end

    it 'rejects unsupported, recurring, and non-conversation post-delivery actions' do
      params[:actions] = [
        {
          action_name: :create_touch,
          action_params: {
            body: 'Final follow-up',
            delay_minutes: 10,
            post_delivery_action: 'send_webhook'
          }
        }
      ]
      expect(FactoryBot.build(:automation_rule, params)).not_to be_valid

      params[:actions][0][:action_params] = {
        body: 'Recurring follow-up',
        scheduled_at: 1.day.from_now.iso8601,
        repeat_mode: 'daily',
        post_delivery_action: 'resolve_conversation'
      }
      expect(FactoryBot.build(:automation_rule, params)).not_to be_valid

      params[:actions][0][:action_params] = {
        action_type: 'ai_agent_wakeup',
        instructions: 'Wake the agent',
        delay_minutes: 10,
        post_delivery_action: 'resolve_conversation'
      }
      expect(FactoryBot.build(:automation_rule, params)).not_to be_valid

      params[:event_name] = 'appointment_created'
      params[:actions][0][:action_params] = {
        body: 'Appointment follow-up',
        delay_minutes: 10,
        post_delivery_action: 'resolve_conversation'
      }
      expect(FactoryBot.build(:automation_rule, params)).not_to be_valid
    end

    it 'allows full create_touch params with absolute recurrence' do
      params[:actions] = [
        {
          action_name: :create_touch,
          action_params: [{
            body: 'Recurring follow-up',
            timing_mode: 'absolute',
            scheduled_at: 1.day.from_now.iso8601,
            repeat_mode: 'daily',
            repeat_until_at: 1.week.from_now.iso8601,
            timezone: 'Asia/Almaty'
          }]
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'allows full create_touch params with WhatsApp template params' do
      params[:actions] = [
        {
          action_name: :create_touch,
          action_params: {
            content_kind: 'channel_template',
            template_params: {
              name: 'payment_reminder',
              language: 'ru',
              processed_params: { body: { '1' => 'Akhan' } }
            },
            timing_mode: 'relative',
            relative_anchor: 'touch.created_at',
            relative_offset_seconds: 1800
          }
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
    end

    it 'rejects full create_touch params with recurring relative timing' do
      params[:actions] = [
        {
          action_name: :create_touch,
          action_params: [{
            body: 'Invalid recurring relative follow-up',
            timing_mode: 'relative',
            relative_anchor: 'touch.created_at',
            relative_offset_seconds: 3600,
            repeat_mode: 'daily'
          }]
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:actions]).to eq(['Automation action parameters create_touch not supported.'])
    end

    it 'rejects cancel_touches touch plans for unsupported entity kinds' do
      touch_plan = create(:reminder_group, account: account, entity_kinds: ['appointment'])
      params[:actions] = [
        {
          action_name: :cancel_touches,
          action_params: [{ reminder_group_id: touch_plan.id }]
        }
      ]

      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be false
      expect(rule.errors.messages[:actions]).to eq(['Automation action parameters cancel_touches not supported.'])
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

    it 'allows account-owned weekday, start-time, and service conditions' do
      account.enable_features!('scheduling')
      service = create(:scheduling_service, account: account)
      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'starts_at_weekday',
          filter_operator: 'equal_to',
          values: %w[1 2],
          query_operator: 'AND'
        },
        {
          attribute_key: 'starts_at_time',
          filter_operator: 'is_greater_than',
          values: ['09:30'],
          query_operator: 'OR'
        },
        {
          attribute_key: 'service_id',
          filter_operator: 'not_equal_to',
          values: [service.id],
          query_operator: nil
        }
      ]
      params[:actions] = [
        {
          action_name: :send_webhook_event,
          action_params: ['https://example.com/hooks/appointments']
        }
      ]

      expect(FactoryBot.build(:automation_rule, params)).to be_valid
    end

    it 'rejects malformed temporal values and cross-account appointment services' do
      account.enable_features!('scheduling')
      foreign_service = create(:scheduling_service)
      params[:event_name] = 'appointment_created'
      params[:conditions] = [
        {
          attribute_key: 'starts_at_weekday',
          filter_operator: 'equal_to',
          values: ['8'],
          query_operator: 'AND'
        },
        {
          attribute_key: 'starts_at_time',
          filter_operator: 'equal_to',
          values: ['24:30'],
          query_operator: 'AND'
        },
        {
          attribute_key: 'service_id',
          filter_operator: 'equal_to',
          values: [foreign_service.id],
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

      expect(rule).not_to be_valid
      expect(rule.errors[:conditions]).to include(
        'Automation condition values starts_at_weekday,starts_at_time,service_id not supported.'
      )
    end

    it 'rejects malformed appointment service identifiers without numeric coercion' do
      account.enable_features!('scheduling')
      service = create(:scheduling_service, account: account)
      params[:event_name] = 'appointment_created'
      params[:actions] = [
        {
          action_name: :send_webhook_event,
          action_params: ['https://example.com/hooks/appointments']
        }
      ]

      malformed_values = [0, -1, service.id.to_f, service.id + 0.5, "#{service.id}.0", BigDecimal(service.id.to_s)]

      aggregate_failures do
        malformed_values.each do |value|
          params[:conditions] = [
            {
              attribute_key: 'service_id',
              filter_operator: 'equal_to',
              values: [value],
              query_operator: nil
            }
          ]

          expect(FactoryBot.build(:automation_rule, params)).not_to be_valid
        end
      end
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

    it 'allows private_note as a valid condition attribute' do
      params[:conditions] = [
        {
          attribute_key: 'private_note',
          filter_operator: 'equal_to',
          values: [true],
          query_operator: nil
        }
      ]
      rule = FactoryBot.build(:automation_rule, params)
      expect(rule.valid?).to be true
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
