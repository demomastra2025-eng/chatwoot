require 'rails_helper'

RSpec.describe Reminders::EnrollmentReminderAttributes do
  describe '#call' do
    it 'uses a database-safe zero offset when materializing the activation anchor' do
      enrollment = instance_double(
        TouchPlanEnrollment,
        id: 7,
        metadata: { 'touch_source' => 'automation' }
      )
      claim = instance_double(TouchOccurrenceClaim, id: 11, occurrence_key: '7:step-1')
      due_at = Time.zone.parse('2026-07-27 16:55:00')
      step = Reminders::EnrollmentScheduleService::Step.new(
        definition: {
          'step_id' => 'step-1',
          'timing_mode' => 'relative',
          'relative_anchor' => 'touch.created_at',
          'relative_offset_seconds' => 60,
          'body' => 'Follow up'
        },
        due_at: due_at,
        index: 0,
        step_key: 'step-1',
        occurrence_key: '7:step-1'
      )
      resolver = instance_double(Reminders::EnrollmentDefinitionResolver, source_revision: 'revision-1')
      allow(Reminders::EnrollmentDefinitionResolver).to receive(:new).with(enrollment: enrollment).and_return(resolver)

      attributes = described_class.new(enrollment: enrollment, step: step, claim: claim).call

      expect(attributes).to include(
        'timing_mode' => 'absolute',
        'scheduled_at' => due_at,
        'relative_anchor' => nil,
        'relative_offset_seconds' => 0,
        'relative_time_mode' => Reminder::RELATIVE_TIME_MODE_INHERIT_ANCHOR_TIME,
        'relative_time_of_day' => nil
      )
    end
  end
end
