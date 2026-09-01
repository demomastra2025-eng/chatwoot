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
end
