require 'rails_helper'

RSpec.describe AutomationRules::AppointmentConditionService do
  let(:account) { create(:account) }
  let(:appointment) { create(:scheduling_appointment, account: account, resource: create(:scheduling_resource, account: account)) }

  before do
    account.enable_features!('scheduling')
  end

  it 'matches discrete appointment conditions' do
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
    )

    expect(described_class.new(rule, appointment).perform).to be(true)
  end

  it 'matches source text conditions' do
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      conditions: [{ attribute_key: 'source', filter_operator: 'contains', values: ['manual'], query_operator: nil }],
      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
    )

    expect(described_class.new(rule, appointment).perform).to be(true)
  end

  it 'supports OR groups across appointment conditions' do
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_updated',
      conditions: [
        { attribute_key: 'status', filter_operator: 'equal_to', values: ['cancelled'], query_operator: 'OR' },
        { attribute_key: 'payment_status', filter_operator: 'equal_to', values: ['awaiting_payment'], query_operator: nil }
      ],
      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
    )

    expect(described_class.new(rule, appointment).perform).to be(true)
  end

  it 'matches weekday and start time in the account reporting timezone' do
    account.update!(reporting_timezone: 'Asia/Almaty')
    starts_at = Time.iso8601('2026-08-23T20:30:45Z')
    appointment.update!(starts_at: starts_at, ends_at: starts_at + 30.minutes)
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      conditions: [
        { attribute_key: 'starts_at_weekday', filter_operator: 'equal_to', values: ['1'], query_operator: 'AND' },
        { attribute_key: 'starts_at_time', filter_operator: 'equal_to', values: ['01:30'], query_operator: nil }
      ],
      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
    )

    expect(described_class.new(rule, appointment).perform).to be(true)

    rule.conditions.first['filter_operator'] = 'not_equal_to'
    rule.conditions.first['values'] = ['0']
    expect(described_class.new(rule, appointment).perform).to be(true)

    rule.conditions.first['filter_operator'] = 'equal_to'
    rule.conditions.first['values'] = ['1']
    rule.conditions.last['filter_operator'] = 'is_less_than'
    rule.conditions.last['values'] = ['01:00']
    expect(described_class.new(rule, appointment).perform).to be(false)

    {
      ['not_equal_to', '01:00'] => true,
      ['is_greater_than', '01:00'] => true,
      ['is_less_than', '02:00'] => true,
      ['is_greater_than', '02:00'] => false
    }.each do |(operator, value), expected|
      rule.conditions.last['filter_operator'] = operator
      rule.conditions.last['values'] = [value]
      expect(described_class.new(rule, appointment).perform).to eq(expected)
    end
  end

  it 'matches any appointment service and preserves AND/OR grouping' do
    primary_service = create(:scheduling_service, account: account)
    secondary_service = create(:scheduling_service, account: account)
    starts_at = Time.iso8601('2026-08-23T20:30:00Z')
    appointment.update!(
      service: primary_service,
      starts_at: starts_at,
      ends_at: starts_at + 30.minutes,
      custom_attributes: { 'service_ids' => [primary_service.id, secondary_service.id] }
    )
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_updated',
      conditions: [
        { attribute_key: 'starts_at_weekday', filter_operator: 'equal_to', values: ['0'], query_operator: 'AND' },
        { attribute_key: 'starts_at_time', filter_operator: 'is_less_than', values: ['01:00'], query_operator: 'OR' },
        { attribute_key: 'service_id', filter_operator: 'equal_to', values: [secondary_service.id], query_operator: nil }
      ],
      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
    )

    expect(described_class.new(rule, appointment).perform).to be(true)

    rule.conditions = [
      { attribute_key: 'service_id', filter_operator: 'not_equal_to', values: [primary_service.id], query_operator: nil }
    ]
    expect(described_class.new(rule, appointment).perform).to be(false)

    unrelated_service = create(:scheduling_service, account: account)
    rule.conditions = [
      { attribute_key: 'service_id', filter_operator: 'not_equal_to', values: [unrelated_service.id], query_operator: nil }
    ]
    expect(described_class.new(rule, appointment).perform).to be(true)

    rule.conditions = [
      { attribute_key: 'service_id', filter_operator: 'equal_to', values: [primary_service.id + 0.5], query_operator: nil }
    ]
    expect(described_class.new(rule, appointment).perform).to be(false)
  end

  it 'distinguishes appointments containing only selected services from mixed appointments' do
    addon_service = create(:scheduling_service, account: account)
    mri_service = create(:scheduling_service, account: account)
    appointment.update!(custom_attributes: { 'service_ids' => [addon_service.id, mri_service.id] })
    rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_updated',
      conditions: [
        { attribute_key: 'service_id', filter_operator: 'not_contains_only', values: [addon_service.id], query_operator: nil }
      ],
      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
    )

    expect(described_class.new(rule, appointment).perform).to be(true)

    appointment.update!(custom_attributes: { 'service_ids' => [addon_service.id] })
    expect(described_class.new(rule, appointment).perform).to be(false)

    rule.conditions = [
      { attribute_key: 'service_id', filter_operator: 'contains_only', values: [addon_service.id], query_operator: nil }
    ]
    expect(described_class.new(rule, appointment).perform).to be(true)
  end

  it 'returns false for unsupported operators' do
    rule = build(
      :automation_rule,
      account: account,
      event_name: 'appointment_updated',
      conditions: [{ attribute_key: 'status', filter_operator: 'contains', values: ['scheduled'], query_operator: nil }],
      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
    )

    expect(described_class.new(rule, appointment).perform).to be(false)
  end

  it 'matches managed discrete appointment custom field conditions' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'select',
      options: [{ 'label' => 'Follow-up', 'value' => 'follow_up' }]
    )

    appointment.update!(custom_attributes: { 'visit_reason' => 'follow_up' })

    rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      conditions: [{ attribute_key: 'visit_reason', filter_operator: 'equal_to', values: ['follow_up'], query_operator: nil,
                     custom_attribute_type: 'appointment_attribute' }],
      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
    )

    expect(described_class.new(rule, appointment).perform).to be(true)
  end

  it 'matches managed advanced appointment custom field conditions' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'triage_note',
      label: 'Triage note',
      field_type: 'text'
    )
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'follow_up_on',
      label: 'Follow up on',
      field_type: 'date'
    )

    appointment.update!(
      custom_attributes: {
        'triage_note' => 'Need follow-up call',
        'follow_up_on' => '2026-03-12'
      }
    )

    rule = create(
      :automation_rule,
      account: account,
      event_name: 'appointment_updated',
      conditions: [
        {
          attribute_key: 'triage_note',
          filter_operator: 'contains',
          values: ['follow-up'],
          query_operator: 'AND',
          custom_attribute_type: 'appointment_attribute'
        },
        {
          attribute_key: 'follow_up_on',
          filter_operator: 'is_greater_than',
          values: ['2026-03-10'],
          query_operator: nil,
          custom_attribute_type: 'appointment_attribute'
        }
      ],
      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }]
    )

    expect(described_class.new(rule, appointment).perform).to be(true)
  end
end
