FactoryBot.define do
  factory :automation_rule_group do
    account
    sequence(:name) { |index| "First match group #{index}" }
    event_name { 'conversation_updated' }
  end

  factory :automation_event do
    account
    sequence(:dedupe_key) { |index| "conversation-updated:#{index}" }
    event_name { 'conversation_updated' }
    subject_type { 'Conversation' }
    sequence(:subject_id)
    schema_version { 1 }
    payload_snapshot { { 'id' => subject_id, 'status' => 'open' } }
    changes_snapshot { { 'status' => %w[pending open] } }
    producer { 'conversation_model' }
    provenance { { 'source' => 'model_callback' } }
    trace_id { SecureRandom.uuid }
    depth { 0 }
    status { 'pending' }
    attempts { 0 }
    next_attempt_at { Time.current }
  end

  factory :automation_execution do
    account
    automation_event { association :automation_event, account: account }
    automation_rule { association :automation_rule, account: account }
    automation_rule_group { automation_rule.automation_rule_group }
    lifecycle_generation { automation_rule.lifecycle_generation }
    definition_version { automation_rule.definition_version }
    schema_version { 1 }
    conditions_snapshot { automation_rule.conditions }
    actions_snapshot { automation_rule.actions }
    execution_schedule_snapshot { automation_rule.execution_schedule }
    scheduled_at { Time.current }
    status { 'pending' }
    attempts { 0 }
    next_attempt_at { Time.current }
  end

  factory :automation_action_receipt do
    account
    automation_execution { association :automation_execution, account: account }
    position { 0 }
    action_id { nil }
    action_signature { nil }
    status { 'pending' }
    attempts { 0 }
    next_attempt_at { Time.current }
  end
end
