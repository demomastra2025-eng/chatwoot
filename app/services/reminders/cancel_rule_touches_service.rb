# frozen_string_literal: true

class Reminders::CancelRuleTouchesService
  def initialize(reason:, rule: nil, account: rule&.account, rule_id: rule&.id, action_ids: nil)
    @rule = rule
    @account = account
    @rule_id = rule_id
    @reason = reason
    @action_ids = action_ids
  end

  def perform
    scope = account.reminders.open_statuses.where(
      'metadata @> ?', { Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => rule_id }.to_json
    )
    scope = scope.where('metadata ->> ? IN (?)', Reminder::AUTOMATION_ACTION_KEY, action_ids) if action_ids
    scope.find_each { |reminder| cancel_one(reminder) }
    cancel_enrollments
  end

  private

  attr_reader :rule, :account, :rule_id, :reason, :action_ids

  def cancel_one(reminder)
    reminder.with_lock do
      next unless reminder.editable?

      reminder.cancel!(reason)
      reminder.update!(metadata: reminder.metadata.to_h.merge('cancelled_via' => reason))
      claim_id = reminder.metadata.to_h['touch_occurrence_claim_id']
      account.touch_occurrence_claims.find_by(id: claim_id)&.update!(status: 'skipped', last_error: reason) if claim_id.present?
    end
  end

  def cancel_enrollments
    return unless rule

    scope = rule.touch_plan_enrollments
    scope = scope.where(source_action_id: action_ids) if action_ids
    scope.where(status: %w[active paused completed]).find_each do |enrollment|
      Reminders::CancelEnrollmentService.new(enrollment: enrollment, reason: reason).perform
    end
  end
end
