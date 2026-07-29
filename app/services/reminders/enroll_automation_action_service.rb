require 'digest'
require 'securerandom'

class Reminders::EnrollAutomationActionService
  attr_reader :account, :action_id, :definition, :remindable, :rule

  def initialize(account:, rule:, action_id:, remindable:, definition:)
    @account = account
    @rule = rule
    @action_id = action_id.to_s
    @remindable = remindable
    @definition = Reminders::DefinitionNormalizer.call(definition)
  end

  def perform(activated_at: Time.current)
    existing_enrollment = open_enrollment
    return existing_enrollment if existing_enrollment.present?

    enrollment = account.touch_plan_enrollments.create!(enrollment_attributes(activated_at))
    Reminders::EnrollmentScheduleService.new(enrollment: enrollment).refresh_next_due!
    enrollment.reload
  rescue ActiveRecord::RecordNotUnique
    open_enrollment || raise
  end

  private

  def enrollment_attributes(activated_at)
    {
      automation_rule: rule,
      source_action_id: action_id,
      remindable: remindable,
      plan_snapshot: [definition],
      plan_digest: Digest::SHA256.hexdigest(definition.to_json),
      activated_at: activated_at,
      idempotency_key: SecureRandom.uuid,
      metadata: {
        'touch_source' => 'automation',
        'actor_type' => rule.class.name,
        'actor_id' => rule.id,
        'allow_terminal_at_activation' => terminal_at_activation?
      }
    }
  end

  def open_enrollment
    account.touch_plan_enrollments.find_by(
      automation_rule: rule,
      source_action_id: action_id,
      remindable: remindable,
      status: %w[active paused completed]
    )
  end

  def terminal_at_activation?
    return remindable.status.in?(%w[cancelled completed no_show]) if remindable.is_a?(Scheduling::Appointment)
    return remindable.closed? || remindable.archived_at.present? if remindable.is_a?(Crm::Deal)

    false
  end
end
