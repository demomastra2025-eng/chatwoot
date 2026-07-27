class Reminders::PlanApplicationResult
  attr_reader :enrollment, :execution_mode, :touches

  def initialize(execution_mode:, touches: [], enrollment: nil)
    @execution_mode = execution_mode.to_s
    @touches = Array(touches)
    @enrollment = enrollment
  end

  def deferred?
    execution_mode == 'deferred'
  end

  def touch_plan
    enrollment&.reminder_group || touches.first&.reminder_group
  end

  def payload_metadata
    {
      execution_mode: execution_mode,
      enrollment_id: enrollment&.id,
      next_due_at: enrollment&.next_due_at&.iso8601
    }.compact
  end
end
