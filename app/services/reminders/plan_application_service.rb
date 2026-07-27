class Reminders::PlanApplicationService
  attr_reader :account, :actor, :remindable, :reminder_group, :source

  def initialize(account:, reminder_group:, remindable:, actor:, source: nil)
    @account = account
    @reminder_group = reminder_group
    @remindable = remindable
    @actor = actor
    @source = source
  end

  def perform
    return eager_result unless deferred?

    enrollment = Reminders::EnrollGroupService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: remindable,
      actor: actor,
      source: source
    ).perform
    Reminders::PlanApplicationResult.new(execution_mode: 'deferred', enrollment: enrollment)
  end

  private

  def deferred?
    Reminders::DeferredMaterializationPolicy.new(
      account: account,
      reminder_group: reminder_group,
      remindable: remindable
    ).eligible?
  end

  def eager_result
    touches = Reminders::ApplyGroupService.new(
      account: account,
      reminder_group: reminder_group,
      remindable: remindable,
      actor: actor
    ).perform
    Reminders::PlanApplicationResult.new(execution_mode: 'eager', touches: touches)
  end
end
