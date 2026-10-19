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
# Cheap by design: the trial accounts are read with three columns, the storage snapshots with one MGET per 1000 accounts,
# the channels with their ids and one MGET per kind of channel, the rest with a handful of counters.
class SuperAdmin::DashboardAlerts
  CACHE_KEY = 'super_admin:dashboard_alerts:v1'
  CACHE_TTL = 2.minutes
  LIST_LIMIT = 10
  TRIAL_ENDING_DAYS = 3
  TRIAL_EXPIRED_DAYS = 7
  # Sidekiq: a queue that has been waiting longer than this (seconds) is behind
  SLOW_QUEUE_SECONDS = SuperAdmin::QueueStats::SLOW_LATENCY
  # OpenRouter: the credits are «low» when this share of the topped-up sum is left
  LOW_CREDITS_SHARE = 0.1
  SNAPSHOT_BATCH = 1000
  # The channels that can ask to be authorized again (Reauthorizable), by class, and the name the alert shows
  REAUTHORIZABLE_CHANNELS = {
    'Channel::Whatsapp' => 'WhatsApp', 'Channel::FacebookPage' => 'Facebook', 'Channel::Instagram' => 'Instagram',
    'Channel::Tiktok' => 'TikTok', 'Channel::Email' => 'Email'
  }.freeze
  # What the OpenRouter key check can say that needs action: status => severity
  OPENROUTER_PROBLEMS = {
    'invalid' => :danger, 'expired' => :danger, 'credits_exhausted' => :danger, 'key_limit_exhausted' => :danger,
    'missing' => :warning, 'unavailable' => :warning
  }.freeze

  def self.build(force_refresh: false)
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL, force: force_refresh) { new.alerts }
  rescue StandardError => e
    Rails.logger.error("[DashboardAlerts] #{e.class.name}: #{e.message}")
    []
  end

  def alerts
    @failed_sources = []
    found = [*trial_alerts, *storage_alerts, *openrouter_alerts, *queue_alerts, *channel_alerts].compact
    found << incomplete_alert if @failed_sources.any?
    found.sort_by.with_index { |alert, index| [alert[:severity] == :danger ? 0 : 1, index] }
  end

  private

  def routes
    Rails.application.routes.url_helpers
  end

  # Runs a check; one that fails is logged and remembered, and gives no alerts
  def checked(source)
    yield
  rescue StandardError => e
    Rails.logger.warn("[DashboardAlerts] #{source} could not be checked: #{e.class.name}: #{e.message}")
    @failed_sources << source
    []
  end

  def text(key, **)
    I18n.t("super_admin.alerts.#{key}", locale: :ru, **)
  end

  def alert(key, severity:, items:, count: items.size, more_url: nil, title: text("#{key}.title"), body: text("#{key}.text"))
    { key: key.to_s.tr('.', '_'), severity: severity, title: title, text: body, count: count, items: items.first(LIST_LIMIT), more_url: more_url }
  end

  def account_item(id, name, note = nil)
    { label: name, url: routes.super_admin_account_path(id), note: note }
  end

  # ------------------------------------------------------------------ trials

  # { id, name, the moment the trial ends } of the accounts that have a trial and are not being deleted
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

  def trial_alerts
    checked('trials') do
      now = Time.current
      ending = trial_accounts.select { |(_id, _name, ends)| ends > now && ends <= now + TRIAL_ENDING_DAYS.days }.sort_by(&:last)
      expired = trial_accounts.select { |(_id, _name, ends)| ends <= now && ends > now - TRIAL_EXPIRED_DAYS.days }.sort_by(&:last).reverse
      [ending_trials_alert(ending, now), expired_trials_alert(expired)]
    end
  end

  def ending_trials_alert(ending, now)
    return if ending.empty?

    items = ending.map do |id, name, ends|
      account_item(id, name, text('trials_ending.note', left: SuperAdmin::DisplayHelper.format_wait((ends - now).to_i),
                                                        time: SuperAdmin::DisplayHelper.format_time(ends)))
    end
    alert(:trials_ending, severity: :warning, items: items, count: ending.size, more_url: accounts_list_url('trial_active:'))
  end

  def expired_trials_alert(expired)
    return if expired.empty?

    items = expired.map { |id, name, ends| account_item(id, name, text('trials_expired.note', time: SuperAdmin::DisplayHelper.format_time(ends))) }
    alert(:trials_expired, severity: :warning, items: items, count: expired.size, more_url: accounts_list_url('trial_expired:'))
  end

  def accounts_list_url(filter)
    routes.super_admin_accounts_path(search: filter)
  end

  # ----------------------------------------------------------------- storage

  # The hourly snapshots (Accounts::StorageOverviewService) say how full the disk quota of every account is; an account
  # without a quota (unlimited) or without a snapshot yet is not a problem to show.
  def storage_alerts
    checked('storage') do
      full = storage_percentages.select { |row| row[:percent] >= SuperAdmin::AccountUsage::WARNING_PERCENT }.sort_by { |row| -row[:percent] }
      critical, warning = full.partition { |row| row[:percent] >= SuperAdmin::AccountUsage::CRITICAL_PERCENT }
      [storage_alert(:storage_critical, :danger, critical), storage_alert(:storage_warning, :warning, warning)]
    end
  end

  def storage_alert(key, severity, rows)
    return if rows.empty?

    items = rows.first(LIST_LIMIT).map do |row|
      note = text('storage.note', percent: row[:percent].round, used: SuperAdmin::DisplayHelper.format_bytes(row[:used]),
                                  total: SuperAdmin::DisplayHelper.format_bytes(row[:total]))
      account_item(row[:id], row[:name], note)
    end
    alert(key, severity: severity, items: items, count: rows.size, more_url: accounts_list_url('storage_high:'))
  end

  def storage_percentages
    accounts = Account.where("custom_attributes->>'marked_for_deletion_at' IS NULL").pluck(:id, :name)
    accounts.each_slice(SNAPSHOT_BATCH).flat_map do |slice|
      snapshots = Accounts::StorageOverviewService.snapshots_for(slice.map(&:first))
      slice.filter_map { |id, name| storage_row(id, name, snapshots[id]&.dig(:limits)) }
    end
  end

  def storage_row(id, name, limits)
    return if limits.blank? || limits[:unlimited] || limits[:total_count].to_i <= 0

    used = limits[:consumed].to_i
    total = limits[:total_count].to_i
    { id: id, name: name, used: used, total: total, percent: used.to_f / total * 100 }
  end

  # -------------------------------------------------------------- OpenRouter

  # Only what the last key check (kept in the cache by Llm::OpenRouterKeyHealth) says. Nothing is asked of OpenRouter here.
  def openrouter_alerts
    checked('openrouter') do
      health = Llm::OpenRouterKeyHealth.metadata.to_h.with_indifferent_access
      status = health[:status].to_s
      if OPENROUTER_PROBLEMS.key?(status)
        [openrouter_alert(status, OPENROUTER_PROBLEMS.fetch(status))]
      elsif credits_low?(health[:credits].to_h.with_indifferent_access)
        [openrouter_alert('credits_low', :warning)]
      else
        []
      end
    end
  end

  def openrouter_alert(status, severity)
    link = { label: text('openrouter.link'), url: "#{routes.super_admin_app_config_path(config: 'captain')}#openrouter-diagnostics", note: nil }
    alert("openrouter.#{status}", severity: severity, items: [link], count: 1)
  end

  def credits_low?(credits)
    return false unless credits[:status] == 'available'

    total = credits[:total_credits].to_f
    remaining = credits[:remaining_credits]
    total.positive? && !remaining.nil? && remaining.to_f.positive? && remaining.to_f <= total * LOW_CREDITS_SHARE
  end

  # ----------------------------------------------------------------- Sidekiq

  def queue_alerts
    checked('sidekiq') do
      stats = SuperAdmin::QueueStats.read
      next [alert(:queues_unavailable, severity: :warning, items: [queues_link], count: 1)] if stats.nil?

      [slow_queues_alert(stats), dead_jobs_alert(stats)]
    end
  end

  def queues_link
    { label: text('queues.link'), url: routes.super_admin_monitoring_path(tab: 'queues'), note: nil }
  end

  def slow_queues_alert(stats)
    slow = stats.queues.select { |queue| queue.latency > SLOW_QUEUE_SECONDS }.sort_by { |queue| -queue.latency }
    return if slow.empty?

    items = slow.map do |queue|
      { label: queue.name, url: routes.super_admin_monitoring_path(tab: 'queues'),
        note: text('queues.waiting', wait: SuperAdmin::DisplayHelper.format_wait(queue.latency), jobs: queue.jobs) }
    end
    alert(:queues_slow, severity: :danger, items: items, count: slow.size)
  end

  def dead_jobs_alert(stats)
    return unless stats.dead.positive?

    alert(:queues_dead, severity: :warning, items: [queues_link], count: stats.dead)
  end

  # ---------------------------------------------------------------- channels

  # The channels the operator has to authorize again (WhatsApp, Facebook, Instagram, TikTok, Email: the ones that keep that
  # mark, see Reauthorizable). The mark lives in Redis, so the ids of the channels are read first and the marks with one MGET.
  def channel_alerts
    checked('channels') do
      flagged = REAUTHORIZABLE_CHANNELS.flat_map { |klass, kind| flagged_channels(klass.constantize).map { |row| row.merge(kind: kind) } }
      next [] if flagged.empty?

      [reauthorization_alert(flagged)]
    end
  end

  # [{ id:, account_id:, class: }] of the channels of one class that need authorizing again
  def flagged_channels(klass)
    rows = klass.pluck(:id, :account_id)
    marked = rows.each_slice(SNAPSHOT_BATCH).flat_map do |slice|
      values = ::Redis::Alfred.mget(slice.map { |id, _account_id| Reauthorizable.required_key(klass, id) })
      slice.zip(values).select { |_row, value| value.present? }.map { |(id, _account_id), _value| id }
    end
    ids = (marked + durable_ids(klass)).to_set
    rows.select { |id, _account_id| ids.include?(id) }.map { |id, account_id| { id: id, account_id: account_id, class: klass.name } }
  end

  # WhatsApp keeps the mark in its settings as well (Whatsapp::DurableReauthorization), so a Redis that lost it does not
  # forget the channel
  def durable_ids(klass)
    return [] unless klass.name == 'Channel::Whatsapp'

    klass.where("LOWER(provider_config->>'reauthorization_required') IN ('true', 't', '1', 'on')").pluck(:id)
  end

  def reauthorization_alert(flagged)
    shown = flagged.sort_by { |row| [row[:account_id], row[:class], row[:id]] }.first(LIST_LIMIT)
    accounts = Account.where(id: shown.pluck(:account_id)).pluck(:id, :name).to_h
    inboxes = Inbox.where(channel_type: shown.pluck(:class).uniq, channel_id: shown.pluck(:id)).pluck(:channel_type, :channel_id, :name)
                   .to_h { |type, id, name| [[type, id], name] }
    items = shown.map do |row|
      account_name = accounts[row[:account_id]] || "##{row[:account_id]}"
      label = [inboxes[[row[:class], row[:id]]], account_name].compact_blank.join(' · ')
      { label: label, url: routes.super_admin_account_path(row[:account_id]), note: row[:kind] }
    end
    alert(:reauthorization, severity: :danger, items: items, count: flagged.size)
  end

  # ------------------------------------------------------------- incomplete

  def incomplete_alert
    names = @failed_sources.uniq.map { |source| text("sources.#{source}") }
    alert(:incomplete, severity: :warning, items: [], count: names.size, body: text('incomplete.text', sources: names.join(', ')))
  end
end
