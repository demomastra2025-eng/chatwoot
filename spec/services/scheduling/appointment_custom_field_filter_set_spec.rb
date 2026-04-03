require 'rails_helper'

RSpec.describe Scheduling::AppointmentCustomFieldFilterSet do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:service) { create(:scheduling_service, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:booking_day) { ActiveSupport::TimeZone['Asia/Almaty'].local(2026, 3, 9, 10, 0, 0) }

  let!(:select_definition) do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_reason',
      label: 'Visit reason',
      field_type: 'select',
      options: [{ 'label' => 'Follow-up', 'value' => 'follow_up' }]
    )
  end

  let!(:multiselect_definition) do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'visit_tags',
      label: 'Visit tags',
      field_type: 'multiselect',
      options: ['VIP', 'Urgent']
    )
  end

  let!(:checkbox_definition) do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'needs_lab',
      label: 'Needs lab',
      field_type: 'checkbox'
    )
  end

  let!(:text_definition) do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'notes',
      label: 'Notes',
      field_type: 'text'
    )
  end

  let!(:date_definition) do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'follow_up_on',
      label: 'Follow up on',
      field_type: 'date'
    )
  end

  let!(:datetime_definition) do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'appointment',
      key: 'triage_at',
      label: 'Triage at',
      field_type: 'datetime'
    )
  end

  let!(:matching_appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      service: service,
      contact: contact,
      starts_at: booking_day,
      ends_at: booking_day + 30.minutes,
      custom_attributes: {
        'notes' => 'Needs follow-up call',
        'follow_up_on' => '2026-03-10',
        'triage_at' => '2026-03-09T10:15:00+05:00',
        'visit_reason' => 'follow_up',
        'visit_tags' => ['VIP'],
        'needs_lab' => true
      }
    )
  end

  let!(:other_appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      service: service,
      contact: contact,
      starts_at: booking_day + 1.hour,
      ends_at: booking_day + 90.minutes,
      custom_attributes: {
        'notes' => 'Routine visit',
        'follow_up_on' => '2026-03-12',
        'triage_at' => '2026-03-09T11:00:00+05:00',
        'visit_reason' => 'initial',
        'visit_tags' => ['Routine'],
        'needs_lab' => false
      }
    )
  end

  it 'matches appointments by select, multiselect, and checkbox values' do
    filter_set = described_class.new(
      account: account,
      raw_filters: {
        visit_reason: ['follow_up'],
        visit_tags: ['VIP'],
        needs_lab: [true]
      }
    )

    expect(filter_set.apply([matching_appointment, other_appointment])).to contain_exactly(matching_appointment)
  end

  it 'ignores unknown or stale filters instead of rejecting the payload' do
    filter_set = described_class.new(
      account: account,
      raw_filters: {
        visit_reason: ['follow_up', 'unknown'],
        unknown_key: ['value']
      }
    )

    expect(filter_set.apply([matching_appointment, other_appointment])).to contain_exactly(matching_appointment)
  end

  it 'matches appointments by text and date filter operators' do
    filter_set = described_class.new(
      account: account,
      raw_filters: {
        notes: { operator: 'contains', value: 'follow-up' },
        follow_up_on: { operator: 'before', value: '2026-03-11' }
      }
    )

    expect(filter_set.apply([matching_appointment, other_appointment])).to contain_exactly(matching_appointment)
  end

  it 'filters an ActiveRecord relation without forcing callers to pre-load arrays' do
    filter_set = described_class.new(
      account: account,
      raw_filters: {
        visit_reason: ['follow_up'],
        notes: { operator: 'contains', value: 'follow-up' }
      }
    )

    expect(filter_set.apply(account.scheduling_appointments.ordered)).to contain_exactly(matching_appointment)
  end

  it 'matches appointments by datetime presence and comparison operators' do
    filter_set = described_class.new(
      account: account,
      raw_filters: {
        triage_at: { operator: 'after', value: '2026-03-09T05:00:00Z' },
        notes: { operator: 'is_present' }
      }
    )

    expect(filter_set.apply([matching_appointment, other_appointment])).to contain_exactly(matching_appointment, other_appointment)
  end

  it 'ignores malformed datetime values when filtering an ActiveRecord relation' do
    other_appointment.update!(
      custom_attributes: other_appointment.custom_attributes.merge('triage_at' => 'sometime-later')
    )
    filter_set = described_class.new(
      account: account,
      raw_filters: {
        triage_at: { operator: 'after', value: '2026-03-09T05:00:00Z' }
      }
    )

    expect { filter_set.apply(account.scheduling_appointments.ordered).to_a }.not_to raise_error
    expect(filter_set.apply(account.scheduling_appointments.ordered)).to contain_exactly(matching_appointment)
  end
end
