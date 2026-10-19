# frozen_string_literal: true

# The trials that end within TRIAL_ENDING_DAYS days (the soonest first) and the ones that ended within TRIAL_EXPIRED_DAYS
# days (the latest first). An account that is being deleted is left out. Only the number, the name, the end of each trial and
# two marks (a plan was applied, the end of the trial left the limits at zero) are read, with one query.
#
# A trial that ended on an account that already has a plan («База + модули» was applied during the trial) is not a problem
# to look at, as the plan stays: it is left out of the expired ones. The exception is a trial whose end put the operator
# and channel limits at zero and left them there (the plans do not set those numbers, so the plan does not give them back):
# that account is listed, and its note says so. The ones that end soon are listed whatever the plan: the functions the trial
# lent beyond the plan switch off when it ends.
class SuperAdmin::DashboardAlerts::Trials < SuperAdmin::DashboardAlerts::Check
  TRIAL_ENDING_DAYS = 3
  TRIAL_EXPIRED_DAYS = 7
  # Whether a plan was applied to the account (the same mark as SuperAdmin::AccountPlanState#assigned?)
  PLAN_ASSIGNED_SQL = "COALESCE(custom_attributes->>'#{Accounts::ApplyPlan::PLAN_KEY}', '') <> ''".freeze
  # Whether the end of the trial left a limit at zero: the trial has its snapshot, the snapshot does not say the end kept the
  # limits, and one of the limits the end locks is the number 0 (the same test as the note «trial_expired» of Accounts::ApplyPlan)
  LIMITS_HELD_SQL = begin
    snapshot = "custom_attributes->'#{Account::TRIAL_SNAPSHOT_KEY}'"
    zero = Account::TRIAL_LOCKED_LIMITS.map do |key|
      "CASE WHEN jsonb_typeof(limits->'#{key}') = 'number' THEN (limits->>'#{key}')::numeric = 0 ELSE false END"
    end
    [
      "(jsonb_typeof(#{snapshot}->'features') = 'array'",
      "COALESCE(#{snapshot}->>'limits_locked', '') <> 'false'",
      "(#{zero.join(' OR ')}))"
    ].join(' AND ').freeze
  end

  # What is read of each account, in the order of Trial
  COLUMNS = [
    'accounts.id', 'accounts.name', "custom_attributes->>'trial_expires_at'", PLAN_ASSIGNED_SQL, LIMITS_HELD_SQL
  ].map { |column| Arel.sql(column) }.freeze

  Trial = Struct.new(:id, :name, :ends_at, :planned, :limits_held)

  def alerts
    now = Time.current
    [ending_alert(ending_trials(now), now), expired_alert(expired_trials(now))].compact
  end

  private

  def ending_trials(now)
    trials.select { |trial| trial.ends_at > now && trial.ends_at <= now + TRIAL_ENDING_DAYS.days }.sort_by(&:ends_at)
  end

  # The trials that ended lately and still need a look, the latest first
  def expired_trials(now)
    lately = trials.select { |trial| trial.ends_at <= now && trial.ends_at > now - TRIAL_EXPIRED_DAYS.days }
    lately.select { |trial| !trial.planned || trial.limits_held }.sort_by(&:ends_at).reverse
  end

  # The accounts that have a trial with a readable end
  def trials
    @trials ||= Account.where("custom_attributes->>'plan_type' = 'trial'")
                       .where("custom_attributes->>'marked_for_deletion_at' IS NULL")
                       .pluck(*COLUMNS)
                       .filter_map { |id, name, raw, planned, held| (ends_at = parse_time(raw)) && Trial.new(id, name, ends_at, planned, held) }
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

    items = expired.map { |trial| account_item(trial.id, trial.name, expired_note(trial)) }
    alert(:trials_expired, severity: :warning, items: items, count: expired.size,
                           more_url: accounts_list_url('trial_expired:'), more_label: text('trials_expired.more'))
  end

  # An account with a plan is listed only because the end of its trial left the limits at zero: the note says so
  def expired_note(trial)
    key = trial.planned ? 'trials_expired.note_held' : 'trials_expired.note'
    text(key, time: SuperAdmin::DisplayHelper.format_time(trial.ends_at))
  end
end
