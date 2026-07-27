class Reminders::MaterializeDueEnrollmentsJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100

  def perform
    processed_ids = []

    BATCH_SIZE.times do
      enrollment_id = process_next_enrollment(processed_ids)
      break if enrollment_id.blank?

      processed_ids << enrollment_id
    end
  end

  private

  def process_next_enrollment(excluded_ids)
    enrollment_id = nil
    account = nil

    TouchPlanEnrollment.transaction do
      enrollment = ordered_candidate_enrollments
                   .where.not(id: excluded_ids)
                   .lock('FOR UPDATE SKIP LOCKED')
                   .first
      next if enrollment.blank?

      enrollment_id = enrollment.id
      account = enrollment.account
      Reminders::MaterializeEnrollmentStepService.new(enrollment: enrollment).perform
    end

    enrollment_id
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: account).capture_exception
    Rails.logger.error("[Touches] Deferred materialization failed for enrollment ##{enrollment_id}: #{e.message}")
    enrollment_id
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
