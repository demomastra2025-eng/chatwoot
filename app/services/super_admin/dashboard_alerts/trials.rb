# frozen_string_literal: true

# The trials that end within TRIAL_ENDING_DAYS days (the soonest first) and the ones that ended within TRIAL_EXPIRED_DAYS
# days (the latest first). An account that is being deleted is left out. Only the number, the name and the end of each trial
# are read, with one query.
class SuperAdmin::DashboardAlerts::Trials < SuperAdmin::DashboardAlerts::Check
  TRIAL_ENDING_DAYS = 3
  TRIAL_EXPIRED_DAYS = 7

  def alerts
    now = Time.current
    ending = trial_accounts.select { |(_id, _name, ends)| ends > now && ends <= now + TRIAL_ENDING_DAYS.days }.sort_by(&:last)
    expired = trial_accounts.select { |(_id, _name, ends)| ends <= now && ends > now - TRIAL_EXPIRED_DAYS.days }.sort_by(&:last).reverse
    [ending_alert(ending, now), expired_alert(expired)].compact
  end

  private

  # [id, name, the moment the trial ends] of the accounts that have a trial with a readable end
  def trial_accounts
    @trial_accounts ||= Account.where("custom_attributes->>'plan_type' = 'trial'")
                               .where("custom_attributes->>'marked_for_deletion_at' IS NULL")
                               .pluck(:id, :name, Arel.sql("custom_attributes->>'trial_expires_at'"))
                               .filter_map { |id, name, raw| (ends = parse_time(raw)) && [id, name, ends] }
  end

  def parse_time(raw)
    Time.zone.parse(raw.to_s) if raw.present?
  rescue ArgumentError
    nil
  end

  def ending_alert(ending, now)
    return if ending.empty?

    items = ending.map do |id, name, ends|
      left = SuperAdmin::DisplayHelper.format_wait((ends - now).to_i)
      account_item(id, name, text('trials_ending.note', left: left, time: SuperAdmin::DisplayHelper.format_time(ends)))
    end
    alert(:trials_ending, severity: :warning, items: items, count: ending.size,
                          more_url: accounts_list_url('trial_active:'), more_label: text('trials_ending.more'))
  end

  def expired_alert(expired)
    return if expired.empty?

    items = expired.map { |id, name, ends| account_item(id, name, text('trials_expired.note', time: SuperAdmin::DisplayHelper.format_time(ends))) }
    alert(:trials_expired, severity: :warning, items: items, count: expired.size,
                           more_url: accounts_list_url('trial_expired:'), more_label: text('trials_expired.more'))
  end
end
