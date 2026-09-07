require 'rails_helper'

RSpec.describe Reminders::ExecutionLockService do
  it 'locks an appointment remindable for an absolute reminder while executing' do
    appointment = create(:scheduling_appointment)
    reminder = create(
      :reminder,
      account: appointment.account,
      remindable: appointment,
      timing_mode: :absolute,
      scheduled_at: 1.minute.ago,
      status: :processing
    )
    execution_updated_at = reminder.updated_at
    appointment_lock_held = false
    allow(reminder).to receive(:remindable).and_return(appointment)
    allow(appointment).to receive(:with_lock).and_wrap_original do |original, &block|
      original.call do
        appointment_lock_held = true
        block.call
      ensure
        appointment_lock_held = false
      end
    end

    result = described_class.new(
      reminder: reminder,
      processing_claim: reminder.processing_claim_token,
      execution_updated_at: execution_updated_at
    ).perform do
      expect(appointment_lock_held).to be(true)
      :executed
    end

    expect(result).to eq(:executed)
  end
end
