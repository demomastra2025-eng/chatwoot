require 'rails_helper'

RSpec.describe AutomationRules::AppointmentConditionService do
  let(:account) { create(:account) }
  let(:appointment) { create(:scheduling_appointment, account: account, resource: create(:scheduling_resource, account: account)) }

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
