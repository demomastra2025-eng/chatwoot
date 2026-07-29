class Reminders::BackfillAutomationRuleEnrollmentsJob < ApplicationJob
  queue_as :scheduled_jobs

  retry_on(
    *Reminders::BackfillAutomationRuleEnrollmentsService::TRANSIENT_DATABASE_ERRORS,
    wait: 3.seconds,
    attempts: 8
  )

  def perform(rule_id, activation_time = nil)
    rule = AutomationRule.find_by(id: rule_id)
    return unless rule

    activation_time ||= rule.updated_at
    return unless rule.active? && rule.updated_at == activation_time

    Reminders::BackfillAutomationRuleEnrollmentsService.new(
      rule: rule,
      activation_time: activation_time
    ).perform
  end
end
