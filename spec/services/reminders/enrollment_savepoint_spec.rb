require 'rails_helper'

RSpec.describe 'Reminder enrollment uniqueness recovery' do
  let(:account) { create(:account) }
  let(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 30.minutes
    )
  end

  it 'recovers an open plan collision without aborting the caller transaction' do
    reminder_group = create(:reminder_group, account: account)
    existing_enrollment = Reminders::EnrollGroupService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: appointment,
      actor: nil
    ).perform
    service = Reminders::EnrollGroupService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: appointment,
      actor: nil
    )
    stub_stale_first_lookup(service)

    ActiveRecord::Base.transaction do
      expect(service.perform).to eq(existing_enrollment)
      expect(ActiveRecord::Base.connection.select_value('SELECT 1')).to eq(1)
    end
  end

  it 'recovers an open automation action collision without aborting the caller transaction' do
    rule = create(:automation_rule, account: account)
    action_id = 'appointment-follow-up'
    definition = {
      action_type: 'send_message',
      content_kind: 'free_text',
      text_mode: 'static',
      timing_mode: 'relative',
      relative_anchor: 'appointment.starts_at',
      relative_offset_seconds: -1.day.to_i,
      timezone: 'UTC',
      body: 'Appointment follow-up'
    }
    existing_enrollment = Reminders::EnrollAutomationActionService.new(
      account: account,
      rule: rule,
      action_id: action_id,
      remindable: appointment,
      definition: definition
    ).perform
    service = Reminders::EnrollAutomationActionService.new(
      account: account,
      rule: rule,
      action_id: action_id,
      remindable: appointment,
      definition: definition
    )
    stub_stale_first_lookup(service)

    ActiveRecord::Base.transaction do
      expect(service.perform).to eq(existing_enrollment)
      expect(ActiveRecord::Base.connection.select_value('SELECT 1')).to eq(1)
    end
  end

  def stub_stale_first_lookup(service)
    lookup_count = 0
    allow(service).to receive(:open_enrollment).and_wrap_original do |original, *args|
      lookup_count += 1
      lookup_count == 1 ? nil : original.call(*args)
    end
  end
end
