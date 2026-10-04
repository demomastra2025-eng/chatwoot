module Crm::Tasks::RequestParams
  CREATE_KEYS = %i[
    context_kind
    deal_id
    status_id
    assignee_id
    creator_id
    team_id
    originating_conversation_id
    title
    description
    task_type_id
    task_outcome_id
    activity_type
    outcome
    outcome_note
    priority
    all_day
    due_on
    schedule_timezone
    start_at
    due_at
    position
    external_ref
    idempotency_key
  ].freeze

  UPDATE_KEYS = %i[
    context_kind
    deal_id
    assignee_id
    creator_id
    team_id
    originating_conversation_id
    title
    description
    task_type_id
    activity_type
    priority
    all_day
    due_on
    schedule_timezone
    start_at
    due_at
    position
    external_ref
    idempotency_key
    lock_version
  ].freeze

  FORM_KEYS = (UPDATE_KEYS + %i[task_outcome_id outcome outcome_note]).freeze

  COMMAND_ONLY_UPDATE_KEYS = %i[
    status_id task_outcome_id outcome outcome_note completed_at completed_by_id
    cancelled_at cancelled_by_id cancellation_reason reschedule_count
  ].freeze
end
