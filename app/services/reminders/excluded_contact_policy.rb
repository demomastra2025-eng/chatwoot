# frozen_string_literal: true

# Holds the touches an automation rule scheduled to the "Contact is not" list the rule has now.
#
# A rule checks its conditions once, when its event fires. A person put on the list afterwards (or a contact merged into
# an excluded one) would still get everything the rule had scheduled before, so the list is read again when a touch is
# about to go out, when an enrollment is about to materialize its next step, and when the rule is edited. An unsent touch
# of an excluded contact is cancelled; a touch whose message already exists is never touched.
#
# The contacts compared are the touch's own target (which can be a third contact reached through a holder route) and the
# contacts of its remindable, the same people the rule's event evaluation looks at.
class Reminders::ExcludedContactPolicy
  CANCEL_REASON = 'contact_excluded'
  CANCELLED_VIA = 'automation_contact_excluded'
  UNSCOPED_PROCESSING_CLAIM = Object.new.freeze

  attr_reader :reminder, :processing_claim

  # True when the rule behind a live-source enrollment excludes a contact of the enrollment's remindable.
  def self.enrollment_excluded?(enrollment)
    rule = enrollment.automation_rule
    return false if rule.blank? || enrollment.remindable.blank?
    return false if AutomationRules::ContactCondition.excluded_ids(rule.conditions).blank?

    AutomationRules::ContactCondition.excludes?(rule.conditions, AutomationRules::ContactCondition.contact_ids_of(enrollment.remindable))
  end

  # processing_claim: pass the claim of the execution that is about to send the touch, then only that execution's
  # processing touch can be cancelled; without it only a draft or pending touch can. rule: the rule when it is known.
  def initialize(reminder:, processing_claim: UNSCOPED_PROCESSING_CLAIM, rule: nil)
    @reminder = reminder
    @execution_scoped = !processing_claim.equal?(UNSCOPED_PROCESSING_CLAIM)
    @processing_claim = @execution_scoped ? processing_claim : nil
    @source_rule = rule if rule
  end

  def cancel_if_excluded!
    return false unless reminder.persisted? && excluded?

    reminder.with_lock do
      reminder.reload
      next false unless excluded?

      cancel!
      true
    end
  end

  def excluded?
    return false unless cancellable_state? && automation_touch?

    rule = source_rule
    return false if rule.blank? || AutomationRules::ContactCondition.excluded_ids(rule.conditions).blank?

    AutomationRules::ContactCondition.excludes?(rule.conditions, contact_ids)
  end

  private

  def cancellable_state?
    return false if reminder.delivery_materialized?
    return reminder.draft? || reminder.pending? unless @execution_scoped

    reminder.processing? && reminder.processing_claim_token == processing_claim
  end

  def automation_touch?
    metadata = reminder.metadata.to_h
    metadata['touch_source'] == 'automation' || metadata[Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY] == 'automation'
  end

  def contact_ids
    ids = [reminder.target_contact_id]
    ids.concat(AutomationRules::ContactCondition.contact_ids_of(reminder.remindable)) if reminder.remindable.present?
    ids.compact.uniq
  end

  def source_rule
    return @source_rule if defined?(@source_rule)

    @source_rule = lookup_rule
  end

  # The rule that scheduled the touch: its own marks, or the rule behind the enrollment that materialized it.
  def lookup_rule
    metadata = reminder.metadata.to_h
    rule_id = metadata['automation_rule_id'].presence || metadata[Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY].presence
    return reminder.account.automation_rules.find_by(id: rule_id) if rule_id.present?

    enrollment_id = metadata['touch_plan_enrollment_id'].presence
    reminder.account.touch_plan_enrollments.find_by(id: enrollment_id)&.automation_rule if enrollment_id.present?
  end

  def cancel!
    cancelled_at = Time.current
    reminder.update!(
      status: :cancelled,
      cancelled_at: cancelled_at,
      processing_started_at: nil,
      last_error: CANCEL_REASON,
      metadata: reminder.metadata.to_h.merge(
        'cancelled_via' => CANCELLED_VIA,
        'cancelled_reason' => CANCEL_REASON,
        'cancelled_at' => cancelled_at.iso8601(6),
        'excluded_by_automation_rule_id' => source_rule.id
      )
    )
    log_cancellation
  end

  def log_cancellation
    Rails.logger.info(
      event: 'automation_contact_excluded_touch_cancelled',
      account_id: reminder.account_id,
      reminder_id: reminder.id,
      automation_rule_id: source_rule.id,
      remindable_type: reminder.remindable_type,
      remindable_id: reminder.remindable_id
    )
  end
end
