class Reminders::DefaultPlanService
  attr_reader :account, :actor, :remindable

  def initialize(account:, remindable:, actor: nil)
    @account = account
    @remindable = remindable
    @actor = actor
  end

  def perform
    return [] if reminder_group.blank?

    Reminders::PlanApplicationService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: remindable,
      actor: actor,
      source: 'default_plan'
    ).perform.touches
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: account).capture_exception
    []
  end

  private

  def reminder_group
    return @reminder_group if defined?(@reminder_group)

    @reminder_group =
      if account.default_touch_plan_id_for(entity_kind).present?
        account.reminder_groups.kept.find_by(id: account.default_touch_plan_id_for(entity_kind))
      end
  end

  def entity_kind
    case remindable
    when Crm::Deal
      'deal'
    when Crm::Task
      'task'
    when Scheduling::Appointment
      'appointment'
    else
      raise ArgumentError, "Default touch plans are not supported for #{remindable.class.name}"
    end
  end
end
