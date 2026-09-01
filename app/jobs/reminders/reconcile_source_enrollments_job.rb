class Reminders::ReconcileSourceEnrollmentsJob < ApplicationJob
  queue_as :scheduled_jobs

  AUTOMATION_RULE_DISABLED = 'automation_rule_disabled'.freeze

  def perform(source_type, source_id, disabled_generation = nil)
    source = source_type.safe_constantize&.find_by(id: source_id)
    return if source.blank?

    generation = disabled_generation_for(source, disabled_generation)
    return reconcile_enrollments(source) if generation.blank?

    cancel_automation_generation(source, generation)
  end

  private

  def disabled_generation_for(source, disabled_generation)
    return unless source.is_a?(AutomationRule)
    return disabled_generation if disabled_generation.present?

    source.lifecycle_generation unless source.active?
  end

  def reconcile_enrollments(source)
    source.touch_plan_enrollments.where(status: %w[active paused completed]).find_each do |enrollment|
      Reminders::ReconcileEnrollmentService.new(enrollment: enrollment).perform
    end
  end

  def cancel_automation_generation(source, disabled_generation)
    cancel_enrollments(source, disabled_generation)
    cancel_direct_reminders(source, disabled_generation)
  end

  def cancel_enrollments(source, disabled_generation)
    source.touch_plan_enrollments
          .where(status: %w[active paused completed])
          .where('source_generation IS NULL OR source_generation <= ?', disabled_generation)
          .find_each do |enrollment|
      Reminders::CancelEnrollmentService.new(
        enrollment: enrollment,
        reason: AUTOMATION_RULE_DISABLED,
        metadata: { 'automation_rule_generation' => disabled_generation }
      ).perform
    end
  end

  def cancel_direct_reminders(source, disabled_generation)
    source.account.reminders
          .open_statuses
          .where(
            'metadata @> ?',
            { Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => source.id }.to_json
          ).where(
            'NOT jsonb_exists(metadata, ?) OR (metadata ->> ?)::bigint <= ?',
            Reminder::AUTOMATION_RULE_GENERATION_KEY,
            Reminder::AUTOMATION_RULE_GENERATION_KEY,
            disabled_generation
          ).find_each do |reminder|
      reminder.cancel!(AUTOMATION_RULE_DISABLED)
    end
  end
end
