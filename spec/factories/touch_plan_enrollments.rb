FactoryBot.define do
  factory :touch_plan_enrollment do
    account { create(:account) }
    reminder_group { create(:reminder_group, account: account) }
    remindable do
      create(
        :scheduling_appointment,
        account: account,
        starts_at: 2.days.from_now,
        ends_at: 2.days.from_now + 30.minutes
      )
    end
    status { 'active' }
    plan_snapshot { reminder_group.touches }
    plan_digest { Digest::SHA256.hexdigest(plan_snapshot.to_json) }
    next_due_at { 1.day.from_now }
    activated_at { Time.current }
    sequence(:idempotency_key) { |n| "touch-enrollment-#{n}" }
    metadata { {} }
  end
end
