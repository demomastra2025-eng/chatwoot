# frozen_string_literal: true

# The block «Нужно проверить» of the «Сводка»: what a super admin should look at first, with a link to each account or
# page. Every check reads what the platform already keeps (counts, the hourly storage snapshots, the cached OpenRouter key
# check, the Sidekiq counters, the marks of channels that need authorizing again): no call to an outside service is made
# when the page is opened. The answer is kept for a short while (CACHE_TTL), so many opened pages cost one run.
#
#   SuperAdmin::DashboardAlerts.build                      # => [alert, ...], the most serious first
#   SuperAdmin::DashboardAlerts.build(force_refresh: true) # the «Обновить» button of the page
#
# An alert is a plain hash (it is cached, and a cached object must survive a new deploy):
#   { key:, severity: :danger | :warning, title:, text:, count:, items: [{ label:, url:, note: }], more_url:, more_label: }
# `count` is the number of things found; `items` hold the first LIST_LIMIT of them; `more_url` opens the whole list and
# `more_label` says which list it is (what the link opens may be wider than what was found: all the trials, not only the
# ones that end soon). A check that cannot be read does not look like «all is well»: the sources that failed are listed in
# one more alert (key `incomplete`), and when nothing could be checked at all (the cache is down) that alert is the only one.
#
# The checks are SuperAdmin::DashboardAlerts::Trials, ::Storage, ::OpenRouter, ::Queues and ::Channels (each answers
# `alerts`). They are cheap by design: the trial accounts are read with three columns, the storage snapshots with one MGET
# per 1000 accounts, the channels with their ids and one MGET per kind of channel, the rest with a handful of counters.
class SuperAdmin::DashboardAlerts
  CACHE_KEY = 'super_admin:dashboard_alerts:v1'
  CACHE_TTL = 2.minutes
  LIST_LIMIT = 10

  # The name of each source (super_admin.alerts.sources) and the check that reads it
  def self.checks
    {
      'trials' => SuperAdmin::DashboardAlerts::Trials, 'storage' => SuperAdmin::DashboardAlerts::Storage,
      'openrouter' => SuperAdmin::DashboardAlerts::OpenRouter, 'sidekiq' => SuperAdmin::DashboardAlerts::Queues,
      'channels' => SuperAdmin::DashboardAlerts::Channels
    }
  end

  def self.build(force_refresh: false)
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL, force: force_refresh) { new.alerts }
  rescue StandardError => e
    # Nothing could be checked or kept: the page says so (and the answer is not cached), it does not look like «all is well»
    Rails.logger.error("[DashboardAlerts] #{e.class.name}: #{e.message}")
    [incomplete_alert(checks.keys, everything: true)]
  end

  # The alert that names the sources that could not be checked; `everything` is true when no source could
  def self.incomplete_alert(failed, everything: false)
    names = failed.map { |source| I18n.t("super_admin.alerts.sources.#{source}", locale: :ru) }
    {
      key: 'incomplete', severity: :warning, title: I18n.t('super_admin.alerts.incomplete.title', locale: :ru),
      text: I18n.t("super_admin.alerts.incomplete.#{everything ? 'text_all' : 'text'}", sources: names.join(', '), locale: :ru),
      count: names.size, items: [], more_url: nil, more_label: nil
    }
  end

  def alerts
    failed = []
    found = self.class.checks.flat_map do |source, check|
      check.new.alerts
    rescue StandardError => e
      # A check that fails is logged and named below, and gives no alerts
      Rails.logger.warn("[DashboardAlerts] #{source} could not be checked: #{e.class.name}: #{e.message}")
      failed << source
      []
    end.compact
    found << self.class.incomplete_alert(failed) if failed.any?
    found.sort_by.with_index { |alert, index| [alert[:severity] == :danger ? 0 : 1, index] }
  end
end
