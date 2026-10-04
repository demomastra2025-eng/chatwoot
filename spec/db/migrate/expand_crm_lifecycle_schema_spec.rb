require 'rails_helper'
require Rails.root.join('db/migrate/20261004120000_expand_crm_lifecycle_schema')

RSpec.describe ExpandCrmLifecycleSchema do
  it 'backfills legacy task timezones and preserves task state and historical deadlines' do
    start_at = Time.utc(2025, 2, 3, 10, 15)
    due_at = Time.utc(2025, 2, 3, 11, 45)
    settings_cases = [
      [{}, 'Asia/Almaty'],
      [{ 'reporting_timezone' => nil }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => '' }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => '   ' }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => 'Not/A_Real_Zone' }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => 'Europe/Berlin' }, 'Europe/Berlin'],
      [{ 'reporting_timezone' => 'Eastern Time (US & Canada)' }, 'America/New_York']
    ]
    task_expectations = settings_cases.map do |settings, expected_timezone|
      account = create(:account)
      task = create(
        :crm_task,
        account: account,
        outcome: 'completed',
        start_at: start_at,
        due_at: due_at
      )
      account.update_columns(settings: settings) # rubocop:disable Rails/SkipsModelValidations -- recreate stored legacy settings rejected by current validation

      [task, expected_timezone, task.status_id]
    end

    described_class.new.send(:backfill_account_timezones)

    task_expectations.each do |task, expected_timezone, status_id|
      expect(task.reload).to have_attributes(
        schedule_timezone: expected_timezone,
        status_id: status_id,
        outcome: 'completed',
        all_day: false,
        due_on: nil,
        start_at: start_at,
        due_at: due_at
      )
    end
  end
end
