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

  def stale_reason(**)
    described_class.new(reminder: reminder, now: now, **).stale_reason
  end

  def update_metadata(changes, without: [])
    reminder.metadata = reminder.metadata.to_h.merge(changes).except(*without)
  end

  it 'cancels a booking or reschedule notice once the visit has started, opted in or not' do
    appointment.starts_at = now
    update_metadata({}, without: [described_class::LATE_IMPORT_OPT_IN_KEY])

    expect(stale_reason).to eq(described_class::STARTED_REASON)

    update_metadata({ Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_rescheduled' })
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

  it 'cancels an after-created confirmation when the visit is less than an hour away' do
    appointment.starts_at = now + 45.minutes
    update_metadata({}, without: [described_class::LATE_IMPORT_OPT_IN_KEY])

    expect(stale_reason).to eq(described_class::SHORT_LEAD_REASON)
  end

  it 'cancels an after-created confirmation if only 45 minutes remain at delivery' do
    appointment.starts_at = now + 45.minutes
    appointment.created_at = now - 2.hours
    update_metadata({}, without: [described_class::LATE_IMPORT_OPT_IN_KEY])

    expect(stale_reason).to eq(described_class::SHORT_LEAD_REASON)
  end

  it 'cancels a delayed touch scheduled relative to its creation when the booking lead time was short' do
    appointment.starts_at = now + 45.minutes
    reminder.relative_anchor = 'touch.created_at'
    reminder.scheduled_at = now + 2.hours
    update_metadata({}, without: [described_class::LATE_IMPORT_OPT_IN_KEY])

    expect(stale_reason).to eq(described_class::SHORT_LEAD_REASON)
  end

  it 'applies the import lag only to MedElement receptions and only to «запись создана»' do
    appointment.source = 'manual'
    expect(stale_reason).to be_nil

    appointment.external_ref = 'medelement:reception:42'
    expect(stale_reason).to eq(described_class::LATE_IMPORT_REASON)

    update_metadata({ Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_rescheduled' })
    expect(stale_reason).to be_nil
  end

  it 'leaves visit-timed reminders, other events, manual touches and materialized deliveries alone' do
    appointment.starts_at = now - 1.minute

    reminder.relative_anchor = 'appointment.starts_at'
    expect(stale_reason).to be_nil

    reminder.relative_anchor = 'appointment.created_at'
    expect(stale_reason).to eq(described_class::STARTED_REASON)

    update_metadata({ Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_cancelled' })
    expect(stale_reason).to be_nil

    update_metadata({ Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_created' }, without: ['touch_source'])
    expect(stale_reason).to be_nil

    update_metadata({ 'touch_source' => 'automation', Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY => 123 })
    reminder.status = 'processing'
    expect(stale_reason).to be_nil
  end

  describe 'a touch that is not a prompt text notice' do
    before do
      appointment.starts_at = now - 1.minute
      update_metadata({}, without: [described_class::LATE_IMPORT_OPT_IN_KEY])
    end

    it 'skips an after-created notice even if it was planned later than an hour after the event' do
      expect(stale_reason).to eq(described_class::STARTED_REASON)

      reminder.assign_attributes(relative_offset_seconds: 3.days.to_i, scheduled_at: now + 3.days)
      expect(stale_reason).to eq(described_class::SHORT_LEAD_REASON)

      reminder.assign_attributes(timing_mode: 'absolute', relative_anchor: nil, relative_offset_seconds: 0, scheduled_at: now + 30.minutes)
      expect(stale_reason).to eq(described_class::STARTED_REASON)
    end

    it 'keeps a touch counted from the touch itself when it was planned days ahead' do
      reminder.assign_attributes(timing_mode: 'absolute', relative_anchor: nil, created_at: now, scheduled_at: now + 2.days)

      expect(stale_reason).to be_nil
    end

    it 'keeps AI wake-ups and repeating series' do
      reminder.action_type = 'ai_agent_wakeup'
      expect(stale_reason).to be_nil

      reminder.action_type = 'send_message'
      reminder.repeat_mode = 'daily'
      expect(stale_reason).to be_nil
    end
  end

  describe 'with the claim of the executing run' do
    before do
      appointment.starts_at = now - 1.minute
      reminder.status = 'processing'
      update_metadata({ Reminder::PROCESSING_CLAIM_KEY => 'claim-1' }, without: [described_class::LATE_IMPORT_OPT_IN_KEY])
    end

    it 'cancels only the touch that run holds' do
      expect(stale_reason(processing_claim: 'claim-1')).to eq(described_class::STARTED_REASON)
      expect(stale_reason(processing_claim: 'claim-2')).to be_nil

      reminder.status = 'pending'
      expect(stale_reason(processing_claim: 'claim-1')).to be_nil
    end

    it 'cancels any open touch when no claim is given' do
      reminder.status = 'pending'

      expect(stale_reason).to eq(described_class::STARTED_REASON)
    end
  end

  describe 'with rule min_minutes_before_appointment configured' do
    it 'cancels a reschedule notice when fewer minutes than configured remained at trigger time' do
      account = create(:account).tap { |record| record.enable_features!('scheduling') }
      rule = create(:automation_rule, account: account, event_name: 'appointment_rescheduled',
                                      min_minutes_before_appointment: 60, conditions: [],
                                      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hook'] }])
      appointment.account = account
      appointment.starts_at = now + 45.minutes
      reminder.created_at = now
      reminder.scheduled_at = now + 1.minute
      update_metadata(
        { Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_rescheduled', 'automation_rule_id' => rule.id },
        without: [described_class::LATE_IMPORT_OPT_IN_KEY]
      )

      expect(stale_reason).to eq(described_class::SHORT_LEAD_REASON)

      appointment.starts_at = now + 60.minutes
      expect(stale_reason).to be_nil
    end

    it 'cancels an appointment_created notice deferred by quiet hours when fewer than configured minutes remain at send time' do
      account = create(:account).tap { |record| record.enable_features!('scheduling') }
      rule = create(:automation_rule, account: account, event_name: 'appointment_created',
                                      min_minutes_before_appointment: 60, conditions: [],
                                      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hook'] }])
      booked_at = Time.zone.parse('2026-10-19 23:00')
      send_at = Time.zone.parse('2026-10-20 09:00')
      appointment.assign_attributes(account: account, created_at: booked_at, starts_at: Time.zone.parse('2026-10-20 09:30'))
      reminder.assign_attributes(timing_mode: 'absolute', relative_anchor: nil, created_at: booked_at, scheduled_at: send_at)
      update_metadata(
        { Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_created', 'automation_rule_id' => rule.id,
          'rescheduled_by_working_hours' => true },
        without: [described_class::LATE_IMPORT_OPT_IN_KEY]
      )

      expect(described_class.new(reminder: reminder, now: send_at).stale_reason).to eq(described_class::SHORT_LEAD_REASON)

      appointment.starts_at = Time.zone.parse('2026-10-20 10:00')
      expect(described_class.new(reminder: reminder, now: send_at).stale_reason).to be_nil
    end

    it 'preserves MedElement hold-release grace when booked 62 minutes ahead and delivered 5 minutes later' do
      account = create(:account).tap { |record| record.enable_features!('scheduling') }
      rule = create(:automation_rule, account: account, event_name: 'appointment_created',
                                      min_minutes_before_appointment: 60, conditions: [],
                                      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hook'] }])
      booked_at = now - 5.minutes
      appointment.assign_attributes(account: account, created_at: booked_at, starts_at: booked_at + 62.minutes)
      reminder.assign_attributes(created_at: now, scheduled_at: now)
      update_metadata(
        { Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_created', 'automation_rule_id' => rule.id },
        without: [described_class::LATE_IMPORT_OPT_IN_KEY]
      )

      expect(stale_reason).to be_nil
    end

    it 'enforces configured min_minutes_before_appointment and after-start protection on appointment_updated notices' do
      account = create(:account).tap { |record| record.enable_features!('scheduling') }
      rule = create(:automation_rule, account: account, event_name: 'appointment_updated',
                                      min_minutes_before_appointment: 60, conditions: [],
                                      actions: [{ action_name: 'send_webhook_event', action_params: ['https://example.com/hook'] }])
      appointment.assign_attributes(account: account, starts_at: now + 45.minutes)
      reminder.assign_attributes(created_at: now, scheduled_at: now + 1.minute)
      update_metadata(
        { Reminder::AUTOMATION_EVENT_NAME_KEY => 'appointment_updated', 'automation_rule_id' => rule.id },
        without: [described_class::LATE_IMPORT_OPT_IN_KEY]
      )

      expect(stale_reason).to eq(described_class::SHORT_LEAD_REASON)

      appointment.starts_at = now - 1.minute
      expect(stale_reason).to eq(described_class::STARTED_REASON)
    end
  end
end
