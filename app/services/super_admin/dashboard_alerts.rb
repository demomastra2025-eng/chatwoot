# frozen_string_literal: true

# The block «Требует внимания» of the «Сводка»: what a super admin should look at first, with a link to each account or
# page. Every check reads what the platform already keeps (counts, the hourly storage snapshots, the cached OpenRouter key
# check, the Sidekiq counters, the marks of channels that need authorizing again): no call to an outside service is made
# when the page is opened. The answer is kept for a short while (CACHE_TTL), so many opened pages cost one run.
#
#   SuperAdmin::DashboardAlerts.build                      # => [alert, ...], the most serious first
#   SuperAdmin::DashboardAlerts.build(force_refresh: true) # the «Обновить» button of the page
#
# An alert is a plain hash (it is cached, and a cached object must survive a new deploy):
#   { key:, severity: :danger | :warning, title:, text:, count:, items: [{ label:, url:, note: }], more_url: }
# `count` is the number of things found; `items` hold the first LIST_LIMIT of them. A check that cannot be read does not
# look like «all is well»: the sources that failed are listed in one more alert (key `incomplete`).
#
# The checks are SuperAdmin::DashboardAlerts::Trials, ::Storage, ::OpenRouter, ::Queues and ::Channels (each answers
# `alerts`). They are cheap by design: the trial accounts are read with three columns, the storage snapshots with one MGET
# per 1000 accounts, the channels with their ids and one MGET per kind of channel, the rest with a handful of counters.
class SuperAdmin::DashboardAlerts
  CACHE_KEY = 'super_admin:dashboard_alerts:v1'
  CACHE_TTL = 2.minutes
  LIST_LIMIT = 10

  def self.build(force_refresh: false)
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL, force: force_refresh) { new.alerts }
  rescue StandardError => e
    Rails.logger.error("[DashboardAlerts] #{e.class.name}: #{e.message}")
    []
  end

  def alerts
    failed = []
    found = checks.flat_map do |source, check|
      check.new.alerts
    rescue StandardError => e
      # A check that fails is logged and named below, and gives no alerts
      Rails.logger.warn("[DashboardAlerts] #{source} could not be checked: #{e.class.name}: #{e.message}")
      failed << source
      []
    end.compact
    found << incomplete_alert(failed) if failed.any?
    found.sort_by.with_index { |alert, index| [alert[:severity] == :danger ? 0 : 1, index] }
  end

  private

  # The name of each source (super_admin.alerts.sources) and the check that reads it
  def checks
    {
      'trials' => SuperAdmin::DashboardAlerts::Trials, 'storage' => SuperAdmin::DashboardAlerts::Storage,
      'openrouter' => SuperAdmin::DashboardAlerts::OpenRouter, 'sidekiq' => SuperAdmin::DashboardAlerts::Queues,
      'channels' => SuperAdmin::DashboardAlerts::Channels
    }
  end

  def incomplete_alert(failed)
    names = failed.map { |source| I18n.t("super_admin.alerts.sources.#{source}", locale: :ru) }
    {
      key: 'incomplete', severity: :warning, title: I18n.t('super_admin.alerts.incomplete.title', locale: :ru),
      text: I18n.t('super_admin.alerts.incomplete.text', sources: names.join(', '), locale: :ru), count: names.size, items: [], more_url: nil
    }
  end
end
