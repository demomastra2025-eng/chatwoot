# frozen_string_literal: true

# Applies the "Contact is not" list a rule has right now to the touches the rule scheduled earlier: every unsent draft or
# pending touch of an excluded contact is cancelled, so a list edit works at once instead of at the next send attempt.
# Touches already being sent are left to the check the sender makes before it delivers.
class Reminders::CancelExcludedContactTouchesService
  OPEN_STATUSES = %w[draft pending].freeze

  attr_reader :rule

  def initialize(rule:)
    @rule = rule
  end

  def perform
    return 0 if AutomationRules::ContactCondition.excluded_ids(rule.conditions).blank?

    cancelled = 0
    rule_touches.find_each do |reminder|
      cancelled += 1 if Reminders::ExcludedContactPolicy.new(reminder: reminder, rule: rule).cancel_if_excluded!
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: rule.account).capture_exception
    end
    cancelled
  end

  private

  def rule_touches
    rule.account.reminders.where(status: OPEN_STATUSES).where(
      'metadata @> :own OR metadata @> :provenance',
      own: { 'automation_rule_id' => rule.id }.to_json,
      provenance: { Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY => rule.id }.to_json
    )
  end
end
