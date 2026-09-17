require 'rails_helper'

RSpec.describe Reminders::ExecutionLockService do
  let(:account) { create(:account) }
  let(:rule) { create(:automation_rule, account: account) }
  let(:reminder) do
    create(:reminder, account: account).tap do |record|
      record.mark_automation_provenance!(rule)
    end
  end

  def execute_with_lock(record)
    processing_claim = record.mark_processing!
    executed = false
    result = described_class.new(
      reminder: record,
      processing_claim: processing_claim,
      execution_updated_at: record.reload.updated_at
    ).perform { executed = true }
    [result, executed]
  end

  it 'executes a reminder from the current active generation', :aggregate_failures do
    result, executed = execute_with_lock(reminder)

    expect(result).to be(true)
    expect(executed).to be(true)
    expect(reminder.reload).to be_processing
  end

  it 'cancels a reminder when its automation rule is disabled', :aggregate_failures do
    record = reminder
    rule.update!(active: false)

    result, executed = execute_with_lock(record)

    expect(result).to be_nil
    expect(executed).to be(false)
    expect(record.reload).to have_attributes(
      status: 'cancelled',
      last_error: described_class::STALE_AUTOMATION_GENERATION
    )
  end

  it 'cancels an old reminder after the automation rule is enabled again', :aggregate_failures do
    record = reminder
    old_generation = record.metadata[Reminder::AUTOMATION_RULE_GENERATION_KEY]
    rule.update!(active: false)
    rule.update!(active: true)

    result, executed = execute_with_lock(record)

    expect(rule.reload.lifecycle_generation).to eq(old_generation + 1)
    expect(result).to be_nil
    expect(executed).to be(false)
    expect(record.reload).to be_cancelled
  end

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
