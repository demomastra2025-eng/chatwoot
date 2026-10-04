require 'rails_helper'

RSpec.describe Crm::AutomationWebhookData do
  let(:account) { create(:account) }

  it 'serializes all-day deadlines, timezone, catalog IDs, and cancellation details' do
    task = create(
      :crm_task,
      account: account,
      all_day: true,
      due_on: Date.new(2026, 10, 5),
      schedule_timezone: 'America/Los_Angeles',
      cancelled_at: Time.zone.parse('2026-10-04 18:30:00'),
      cancellation_reason: 'Customer asked to follow up next week'
    )

    task_payload = described_class.new(task).call.fetch(:task)

    expect(task_payload).to include(
      all_day: true,
      due_on: Date.new(2026, 10, 5),
      schedule_timezone: 'America/Los_Angeles',
      task_type_id: task.task_type_id,
      task_outcome_id: task.task_outcome_id,
      cancelled_at: task.cancelled_at,
      cancellation_reason: 'Customer asked to follow up next week'
    )
  end
end
