require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentImporterService do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  it 're-times a direct reminder when the provider moves a visit to another day' do
    account = create(:account)
    resource = create(:scheduling_resource, account: account)
    contact = create(:contact, account: account, phone_number: '+77000000001')
    conversation = create(:conversation, account: account, contact: contact)
    service = described_class.new(account: account)
    starts_at = 4.days.from_now
    context = { starts_at: starts_at, ends_at: starts_at + 30.minutes, specialist_code: 'fake-specialist' }
    reception = { 'RECEPTION_CODE' => 'fake-reception', 'PATIENT_CODE' => 'fake-patient', 'ACTIVE' => 1 }
    appointment = service.upsert!(resource: resource, contact: contact, reception: reception, import_context: context)
    touch = create(:reminder, account: account, remindable: appointment, touch_conversation: conversation, timing_mode: 'relative',
                              relative_anchor: 'appointment.starts_at', relative_offset_seconds: -2.hours.to_i,
                              scheduled_at: nil, metadata: { 'touch_source' => 'automation' })
    second_start = starts_at + 3.hours
    second = service.upsert!(resource: resource, contact: contact,
                             reception: reception.merge('RECEPTION_CODE' => 'another-fake-reception'),
                             import_context: context.merge(starts_at: second_start, ends_at: second_start + 30.minutes))
    other_touch = create(:reminder, account: account, remindable: second, touch_conversation: conversation, timing_mode: 'relative',
                                    relative_anchor: 'appointment.starts_at', relative_offset_seconds: -2.hours.to_i,
                                    scheduled_at: nil, metadata: { 'touch_source' => 'automation' }, body: 'Other reminder')
    other_due = other_touch.scheduled_at

    moved = starts_at + 1.day
    service.upsert!(resource: resource, contact: contact, reception: reception,
                    import_context: context.merge(starts_at: moved, ends_at: moved + 30.minutes))

    expect(touch.reload.scheduled_at.to_i).to eq((moved - 2.hours).to_i)
    expect(touch).to be_pending
    expect(other_touch.reload.scheduled_at).to eq(other_due)
  end

  it 'respects min_minutes_before_appointment when MedElement imports short-lead vs long-lead receptions' do
    travel_to(Time.zone.parse('2026-11-02 10:00:00')) do
      account = create(:account).tap { |record| record.enable_features!('scheduling') }
      resource = create(:scheduling_resource, account: account)
      contact = create(:contact, account: account, phone_number: '+77000000002')
      create(:conversation, account: account, contact: contact)
      create(
        :automation_rule, account: account, event_name: 'appointment_created', active: true,
                          min_minutes_before_appointment: 60,
                          conditions: [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }],
                          actions: [{ action_name: 'create_touch', action_params: [{
                            action_type: 'send_message', content_kind: 'free_text', body: 'Вы записаны',
                            timing_mode: 'relative', relative_anchor: 'touch.created_at', relative_offset_seconds: 60
                          }] }]
      )
      service = described_class.new(account: account)

      short_appt = nil
      ok_appt = nil
      perform_enqueued_jobs(only: EventDispatcherJob) do
        short_appt = service.upsert!(
          resource: resource, contact: contact,
          reception: { 'RECEPTION_CODE' => 'short-rec', 'PATIENT_CODE' => 'p-1', 'ACTIVE' => 1 },
          import_context: { starts_at: 45.minutes.from_now, ends_at: 75.minutes.from_now, specialist_code: 'sp-1' }
        )
        ok_appt = service.upsert!(
          resource: resource, contact: contact,
          reception: { 'RECEPTION_CODE' => 'ok-rec', 'PATIENT_CODE' => 'p-1', 'ACTIVE' => 1 },
          import_context: { starts_at: 60.minutes.from_now, ends_at: 90.minutes.from_now, specialist_code: 'sp-1' }
        )
      end

      expect(account.reminders.where(remindable: short_appt)).to be_empty
      expect(account.reminders.where(remindable: ok_appt).count).to eq(1)
    end
  end
end
