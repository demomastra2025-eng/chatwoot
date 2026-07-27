require 'digest'
require 'securerandom'

class Reminders::EnrollGroupService
  attr_reader :account, :actor, :remindable, :reminder_group, :source

  def initialize(account:, reminder_group:, remindable:, actor:, source: nil)
    @account = account
    @reminder_group = reminder_group
    @remindable = remindable
    @actor = actor
    @source = source
  end

  def perform
    existing_enrollment = open_enrollment
    return existing_enrollment if existing_enrollment.present?

    definitions = normalized_definitions
    digest = Digest::SHA256.hexdigest(definitions.to_json)
    enrollment = account.touch_plan_enrollments.create!(
      remindable: remindable,
      reminder_group: reminder_group,
      plan_snapshot: definitions,
      plan_digest: digest,
      activated_at: Time.current,
      idempotency_key: SecureRandom.uuid,
      metadata: provenance_metadata
    )
    Reminders::EnrollmentScheduleService.new(enrollment: enrollment).refresh_next_due!
    enrollment.reload
  rescue ActiveRecord::RecordNotUnique
    open_enrollment || raise
  end

  private

  def normalized_definitions
    reminder_group.touches.map { |definition| Reminders::DefinitionNormalizer.call(definition) }
  end

  def open_enrollment
    account.touch_plan_enrollments.find_by(
      reminder_group: reminder_group,
      remindable: remindable,
      status: %w[active paused]
    )
  end

  def provenance_metadata
    {
      'touch_source' => source.presence || actor_source,
      'actor_type' => actor&.class&.name,
      'actor_id' => actor&.id
    }.compact
  end

  def actor_source
    return 'automation' if actor.is_a?(AutomationRule)
    return 'user' if actor.is_a?(User)

    'default_plan'
  end
end
