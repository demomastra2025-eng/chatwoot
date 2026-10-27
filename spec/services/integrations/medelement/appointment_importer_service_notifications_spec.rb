require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentImporterService do
  it 're-times a direct reminder when the provider moves a visit to another day' do
    account = create(:account)
    resource = create(:scheduling_resource, account: account)
    contact = create(:contact, account: account, phone_number: '+77000000001')
    service = described_class.new(account: account)
    starts_at = 4.days.from_now
    context = { starts_at: starts_at, ends_at: starts_at + 30.minutes, specialist_code: 'fake-specialist' }
    reception = { 'RECEPTION_CODE' => 'fake-reception', 'PATIENT_CODE' => 'fake-patient', 'ACTIVE' => 1 }
    appointment = service.upsert!(resource: resource, contact: contact, reception: reception, import_context: context)
    touch = create(:reminder, account: account, remindable: appointment, timing_mode: 'relative',
                              relative_anchor: 'appointment.starts_at', relative_offset_seconds: -2.hours.to_i,
                              scheduled_at: nil, metadata: { 'touch_source' => 'automation' })
    second_start = starts_at + 3.hours
    second = service.upsert!(resource: resource, contact: contact,
                             reception: reception.merge('RECEPTION_CODE' => 'another-fake-reception'),
                             import_context: context.merge(starts_at: second_start, ends_at: second_start + 30.minutes))
    other_touch = create(:reminder, account: account, remindable: second, timing_mode: 'relative',
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
end
