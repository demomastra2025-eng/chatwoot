class Reminders::MaterializeDueEnrollmentsJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100
  MAX_CHAINED_BATCHES = 10
  MAX_DUE_STEPS_PER_ENROLLMENT = 100

  def perform(batch_number = 0, excluded_ids = [])
    processed_ids = Array(excluded_ids).map(&:to_i)
    batch_ids = []

    BATCH_SIZE.times do
      enrollment_id = process_next_enrollment(processed_ids)
      break if enrollment_id.blank?

      processed_ids << enrollment_id
      batch_ids << enrollment_id
    end

    enqueue_next_batch(batch_number, processed_ids, batch_ids)
    Reminders::ProcessPendingRemindersJob.perform_later if batch_ids.any?
  end

  private

  def enqueue_next_batch(batch_number, processed_ids, batch_ids)
    return if batch_ids.size < BATCH_SIZE
    return if batch_number >= MAX_CHAINED_BATCHES
    return unless candidate_enrollments.where.not(id: processed_ids).exists?

    self.class.perform_later(batch_number + 1, processed_ids)
  end

  def process_next_enrollment(excluded_ids)
    state = { enrollment_id: nil, account: nil }
    processed_steps = drain_due_steps(state, excluded_ids)
    warn_if_due_steps_remain(state[:enrollment_id]) if processed_steps == MAX_DUE_STEPS_PER_ENROLLMENT
    state[:enrollment_id]
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: state[:account]).capture_exception
    Rails.logger.error("[Touches] Deferred materialization failed for enrollment ##{state[:enrollment_id]}: #{e.message}")
    state[:enrollment_id]
  end

  def drain_due_steps(state, excluded_ids)
    MAX_DUE_STEPS_PER_ENROLLMENT.times do |index|
      return index unless process_due_step(state, excluded_ids)
    end
    MAX_DUE_STEPS_PER_ENROLLMENT
  end

  def process_due_step(state, excluded_ids)
    processed_step = false
    TouchPlanEnrollment.transaction do
      enrollment = locked_enrollment(state[:enrollment_id], excluded_ids)
      next if enrollment.blank?

      state[:enrollment_id] ||= enrollment.id
      state[:account] ||= enrollment.account
      Reminders::MaterializeEnrollmentStepService.new(enrollment: enrollment).perform
      processed_step = true
    end
    processed_step
  end

  def locked_enrollment(enrollment_id, excluded_ids)
    scope = if enrollment_id.present?
              candidate_enrollments.where(id: enrollment_id)
            else
              ordered_candidate_enrollments.where.not(id: excluded_ids)
            end
    scope.lock('FOR UPDATE SKIP LOCKED').first
  end

  def warn_if_due_steps_remain(enrollment_id)
    return if enrollment_id.blank? || !candidate_enrollments.exists?(id: enrollment_id)

    Rails.logger.warn(
      "[Touches] Deferred materialization capped at #{MAX_DUE_STEPS_PER_ENROLLMENT} due steps for enrollment ##{enrollment_id}"
    )
  end

  def ordered_candidate_enrollments
    candidate_enrollments.order(
      Arel.sql("CASE WHEN touch_plan_enrollments.status = 'paused' THEN 0 ELSE 1 END"),
      :next_due_at,
      :id
    )
  end

  def candidate_enrollments
    feature_name = Reminders::DeferredMaterializationPolicy::FEATURE_NAME
    due_ids = TouchPlanEnrollment.due.select(:id)
    resumable_ids = TouchPlanEnrollment
                    .paused_by_feature(feature_name)
                    .joins(:account)
                    .where('accounts.feature_flags_overflow @> ?', [feature_name].to_json)
                    .select(:id)

    TouchPlanEnrollment.where(id: due_ids).or(TouchPlanEnrollment.where(id: resumable_ids))
  end
end
