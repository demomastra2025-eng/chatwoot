# frozen_string_literal: true

# The trials that end within TRIAL_ENDING_DAYS days (the soonest first) and the ones that ended within TRIAL_EXPIRED_DAYS
# days (the latest first). An account that is being deleted is left out. Only the number, the name, the end of each trial and
# whether the account has a plan are read, with one query.
#
# A trial that ended on an account that already has a plan («База + модули» was applied during the trial) is not a problem
# to look at: the plan stays, and so do the limits (a trial on an account with a plan keeps them). Only the trials that
# ended on an account without a plan are listed as expired. The ones that end soon are listed whatever the plan: the
# functions the trial lent beyond the plan switch off when it ends.
class SuperAdmin::DashboardAlerts::Trials < SuperAdmin::DashboardAlerts::Check
  TRIAL_ENDING_DAYS = 3
  TRIAL_EXPIRED_DAYS = 7
  # Whether a plan was applied to the account (the same mark as SuperAdmin::AccountPlanState#assigned?)
  PLAN_ASSIGNED_SQL = "COALESCE(custom_attributes->>'#{Accounts::ApplyPlan::PLAN_KEY}', '') <> ''".freeze

  Trial = Struct.new(:id, :name, :ends_at, :planned)

  def alerts
    now = Time.current
    [ending_alert(ending_trials(now), now), expired_alert(expired_trials(now))].compact
  end

  private

  def ending_trials(now)
    trials.select { |trial| trial.ends_at > now && trial.ends_at <= now + TRIAL_ENDING_DAYS.days }.sort_by(&:ends_at)
  end

  # The trials that ended lately on accounts without a plan, the latest first
  def expired_trials(now)
    trials.select { |trial| !trial.planned && trial.ends_at <= now && trial.ends_at > now - TRIAL_EXPIRED_DAYS.days }
          .sort_by(&:ends_at).reverse
  end

  # The accounts that have a trial with a readable end
  def trials
    @trials ||= Account.where("custom_attributes->>'plan_type' = 'trial'")
                       .where("custom_attributes->>'marked_for_deletion_at' IS NULL")
                       .pluck(:id, :name, Arel.sql("custom_attributes->>'trial_expires_at'"), Arel.sql(PLAN_ASSIGNED_SQL))
                       .filter_map { |id, name, raw, planned| (ends_at = parse_time(raw)) && Trial.new(id, name, ends_at, planned) }
  end

  def parse_time(raw)
    Time.zone.parse(raw.to_s) if raw.present?
  rescue ArgumentError
    nil
  end

  def ending_alert(ending, now)
    return if ending.empty?

    items = ending.map do |trial|
      left = SuperAdmin::DisplayHelper.format_wait((trial.ends_at - now).to_i)
      account_item(trial.id, trial.name, text('trials_ending.note', left: left, time: SuperAdmin::DisplayHelper.format_time(trial.ends_at)))
    end
    alert(:trials_ending, severity: :warning, items: items, count: ending.size,
                          more_url: accounts_list_url('trial_active:'), more_label: text('trials_ending.more'))
  end

  def expired_alert(expired)
    return if expired.empty?

    items = expired.map do |trial|
      account_item(trial.id, trial.name, text('trials_expired.note', time: SuperAdmin::DisplayHelper.format_time(trial.ends_at)))
    end
    alert(:trials_expired, severity: :warning, items: items, count: expired.size,
                           more_url: accounts_list_url('trial_expired:'), more_label: text('trials_expired.more'))
  end
end
