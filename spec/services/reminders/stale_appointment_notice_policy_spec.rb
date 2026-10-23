require 'rails_helper'

RSpec.describe Reminders::StaleAppointmentNoticePolicy do
  let(:now) { Time.zone.parse('2026-10-20 10:00') }
  let(:appointment) do
    Scheduling::Appointment.new(
      source: 'medelement',
      starts_at: now + 1.day,
      created_at: now,
      custom_attributes: {
        'medelement_source_created_at' => (now - 2.hours).utc.strftime('%Y-%m-%d %H:%M:%S'),
        'medelement_source_timezone' => 'UTC'
      }
    )
  end
  let(:event_name) { 'appointment_created' }
  let(:metadata) do
    {
      'touch_source' => 'automation',
      Reminder::AUTOMATION_EVENT_NAME_KEY => event_name,
      described_class::LATE_IMPORT_OPT_IN_KEY => true
    }
  end
  let(:reminder) do
    Reminder.new(
      status: 'pending',
      timing_mode: 'relative',
      relative_anchor: 'appointment.created_at',
      relative_offset_seconds: 60,
      metadata: metadata,
      remindable: appointment
    )
  end

  def stale_reason
    described_class.new(reminder: reminder, now: now).stale_reason
  end

  def update_metadata(changes, without: [])
    reminder.metadata = reminder.metadata.to_h.merge(changes).except(*without)
  end

  it 'cancels a booking or reschedule notice once the visit has started, opted in or not' do
    appointment.starts_at = now
    update_metadata({}, without: [described_class::LATE_IMPORT_OPT_IN_KEY])

    expect(stale_reason).to eq(described_class::STARTED_REASON)

    update_metadata(Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_rescheduled')
    reminder.assign_attributes(timing_mode: 'absolute', relative_anchor: nil, scheduled_at: now)
    expect(stale_reason).to eq(described_class::STARTED_REASON)
  end

  it 'skips a «запись создана» notice for a reception imported more than an hour late when the action opted in' do
    expect(stale_reason).to eq(described_class::LATE_IMPORT_REASON)

    update_metadata({}, without: [described_class::LATE_IMPORT_OPT_IN_KEY])
    expect(stale_reason).to be_nil
  end

  it 'keeps a notice whose reception reached OneLink within the hour' do
    appointment.custom_attributes['medelement_source_created_at'] = (now - 59.minutes).utc.strftime('%Y-%m-%d %H:%M:%S')

    expect(stale_reason).to be_nil
  end

  it 'applies the import lag only to MedElement receptions and only to «запись создана»' do
    appointment.source = 'manual'
    expect(stale_reason).to be_nil

    appointment.external_ref = 'medelement:reception:42'
    expect(stale_reason).to eq(described_class::LATE_IMPORT_REASON)

    update_metadata(Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_rescheduled')
    expect(stale_reason).to be_nil
  end

  it 'leaves visit-timed reminders, other events, manual touches and materialized deliveries alone' do
    appointment.starts_at = now - 1.minute

    reminder.relative_anchor = 'appointment.starts_at'
    expect(stale_reason).to be_nil

    reminder.relative_anchor = 'appointment.created_at'
    expect(stale_reason).to eq(described_class::STARTED_REASON)

    update_metadata(Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_cancelled')
    expect(stale_reason).to be_nil

    update_metadata({ Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_created' }, without: ['touch_source'])
    expect(stale_reason).to be_nil

    update_metadata('touch_source' => 'automation', Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY => 123)
    reminder.status = 'processing'
    expect(stale_reason).to be_nil
  end
end
