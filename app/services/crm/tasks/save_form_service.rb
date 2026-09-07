# A form is one command: its domain operations and receipt commit together.
# Child operations keep their audit facts but never publish intermediate UI state.
class Crm::Tasks::SaveFormService < Crm::Tasks::CommandService
  DETAIL_KEYS = %i[
    context_kind deal_id creator_id team_id originating_conversation_id title description
    task_type_id task_outcome_id activity_type outcome outcome_note priority
    position external_ref custom_attributes
  ].freeze
  SCHEDULE_KEYS = Crm::Tasks::RescheduleService::SCHEDULE_KEYS
  STATUS_KEYS = %i[status_id task_outcome_id outcome outcome_note cancellation_reason position].freeze

  def perform
    validate_request!
    ApplicationRecord.transaction do
      task.lock!
      previous_result = find_idempotent_task
      next previous_result if previous_result

      assert_lock_version!
      before_data = state_snapshot
      save_details!
      run_operation(Crm::Tasks::AssignService, params.slice(:assignee_id)) if params.key?(:assignee_id)
      schedule = params.slice(*SCHEDULE_KEYS)
      run_operation(Crm::Tasks::RescheduleService, schedule) if schedule.present?
      save_status!
      record_command_event!(before_data)
      Crm::AfterCommit.run { publish_realtime!(task.reload) }
      task.reload
    end
  end

  private

  def event_type
    'task_form_saved'
  end

  def validate_request!
    validation_error!('idempotency_key', 'is required') unless params[:idempotency_key].is_a?(String) && params[:idempotency_key].present?
    validation_error!('lock_version', 'must be a non-negative integer') unless params[:lock_version].to_s.match?(/\A\d+\z/)
  end

  def save_details!
    details = params.slice(*DETAIL_KEYS)
    return if details.empty?

    run_operation(Crm::Tasks::UpsertService, details)
  end

  def save_status!
    return unless params.key?(:status_id)
    return if params[:status_id].to_s == task.status_id.to_s

    run_operation(Crm::Tasks::StatusTransitionService, params.slice(*STATUS_KEYS))
  end

  def run_operation(service_class, attributes)
    service_class.new(
      account: account, task: task, actor: actor,
      params: attributes.merge(lock_version: task.lock_version), broadcast: false
    ).perform
  end

  def state_snapshot
    task.serializable_hash(only: SNAPSHOT_KEYS + DETAIL_KEYS.map(&:to_s))
  end

  def fingerprint_payload
    canonical_payload(params.except(:lock_version, :idempotency_key))
  end

  def canonical_payload(value)
    case value
    when Hash
      value.sort_by { |key, _| key.to_s }.to_h.transform_values { |item| canonical_payload(item) }
    when Array
      value.map { |item| canonical_payload(item) }
    else
      value
    end
  end
end
