require 'rails_helper'

RSpec.describe Reminders::EnrollmentDefinitionResolver do
  let(:account) { create(:account) }
  let(:appointment) { create(:scheduling_appointment, account: account) }
  let(:reminder_group) do
    create(
      :reminder_group,
      account: account,
      entity_kinds: %w[appointment deal],
      touches: [
        {
          entity_kind: 'appointment',
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: 60,
          body: 'Appointment live step'
        },
        {
          entity_kind: 'deal',
          timing_mode: 'relative',
          relative_anchor: 'deal.expected_close_on',
          relative_offset_seconds: 60,
          body: 'Deal live step'
        }
      ]
    )
  end
  let(:enrollment) do
    create(
      :touch_plan_enrollment,
      account: account,
      reminder_group: reminder_group,
      remindable: appointment
    )
  end

  it 'returns only live definitions applicable to the enrolled entity' do
    expect(described_class.new(enrollment: enrollment).definitions.pluck('body')).to eq(['Appointment live step'])
  end
end
