# frozen_string_literal: true

# The headline figures of the «Сводка» (the tiles above «Нужно проверить») and the data of its chart. Every figure is one cheap
# query on what the platform already keeps (a count of accounts by status, the trial dates read as plain text, the messages and
# the conversations of the last day or month), and the answer is kept for a short while (CACHE_TTL), so many opened pages cost
# one run.
#
#   SuperAdmin::DashboardSummary.build                      # => { active: 12, ..., chart: [[Date, count], ...] }
#   SuperAdmin::DashboardSummary.build(force_refresh: true) # the «Обновить» button of the page
#
# The answer is a plain hash (it is cached, and a cached object must survive a new deploy). A figure that could not be counted
# is nil, not zero: the tile says «нет данных» instead of a number that looks like «nothing happened». The accounts are counted
# the way the lists of accounts count them (AccountDashboard::COLLECTION_FILTERS: «Активные», «Пробные», «Заблокированные»,
# «Новые за 30 дней»), so a tile and the list it opens always show the same number.
class SuperAdmin::DashboardSummary
  CACHE_KEY = 'super_admin:dashboard_summary:v1'
  CACHE_TTL = 2.minutes
  # A trial that ends within this many days is counted as «ending»
  TRIAL_ENDING_DAYS = SuperAdmin::DashboardAlerts::Trials::TRIAL_ENDING_DAYS
  RECENT_DAYS = 30
  CHART_DAYS = 30

  FIGURES = %i[active suspended trial trial_ending recent messages_day].freeze

  def self.build(force_refresh: false)
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL, force: force_refresh) { new.figures }
  rescue StandardError => e
    # Nothing could be counted or kept: every tile says «нет данных» (and the answer is not cached)
    Rails.logger.error("[DashboardSummary] #{e.class.name}: #{e.message}")
    FIGURES.index_with { nil }.merge(chart: [])
  end

  def figures
    statuses = guarded(:statuses) { Account.group(:status).count }
    trials = guarded(:trials) { trial_counts }
    {
      active: statuses&.fetch('active', 0), suspended: statuses&.fetch('suspended', 0),
      trial: trials&.fetch(:active), trial_ending: trials&.fetch(:ending),
      recent: guarded(:recent) { AccountDashboard::COLLECTION_FILTERS.fetch(:recent).call(Account.all).count },
      messages_day: guarded(:messages_day) { Message.unscoped.chat.where(created_at: 1.day.ago..).count },
      chart: guarded(:chart) { conversations_per_day } || []
    }
  end

  private

  # A figure that cannot be counted is logged and nil; the others are still counted
  def guarded(name)
    yield
  rescue StandardError => e
    Rails.logger.warn("[DashboardSummary] #{name} could not be counted: #{e.class.name}: #{e.message}")
    nil
  end

  # The trials that are running now and the ones that end soon. The dates are plain text in the attributes of the account and
  # are read in Ruby: a date that cannot be read is left out, it does not break the count.
  def trial_counts
    now = Time.current
    raws = Account.where("custom_attributes->>'plan_type' = 'trial'").pluck(Arel.sql("custom_attributes->>'trial_expires_at'"))
    running = raws.filter_map { |raw| parse_time(raw) }.select { |ends_at| ends_at > now }
    { active: running.size, ending: running.count { |ends_at| ends_at <= now + TRIAL_ENDING_DAYS.days } }
  end

  def parse_time(raw)
    Time.zone.parse(raw.to_s) if raw.present?
  rescue ArgumentError
    nil
  end

  # [[day, count], ...] of the conversations created in the last CHART_DAYS days, every day of them
  def conversations_per_day
    Conversation.unscoped.group_by_day(:created_at, range: CHART_DAYS.days.ago..2.seconds.ago).count.to_a
  end
end
