# frozen_string_literal: true

# The list «Нужно проверить» of the «Сводка»: ONE short list of what a super admin should look at, the most serious first. It
# merges the two things the page used to show apart: the alerts (SuperAdmin::DashboardAlerts: trials, disk space, the OpenRouter
# key, the queues, channels to authorize again) and the problems of the table of accounts (SuperAdmin::HealthMatrixService:
# telephony, MedElement, messages that did not go out). It only rearranges what those two already computed: no query is made here.
#
#   checklist = SuperAdmin::DashboardChecklist.build(alerts: alerts, health_accounts: accounts, health_summary: summary)
#   checklist.rows      # => [row, ...], the most serious first
#   checklist.total     # => how many problems there are in all (the tile «Требуют внимания» shows the same number)
#   checklist.severity  # => :danger, :warning or nil (nothing to check): the colour of the badge of the list
#
# A row is a plain hash: what is wrong, which account, one button to the place where it is put right:
#   { key:, severity: :danger | :warning, title:, subject: (the account, or «Вся платформа»), note:, hint:, details: [text, ...],
#     action: { label:, url: }, more: false }
# A row with `more: true` is not a problem: it follows the rows of one kind of problem and says that only the first ones are listed.
# `details` hold what only a developer reads (the names of queues): the page folds them under «Для разработчика».
#
# The problems of a blocked account are not listed: it is stopped on purpose, nobody can put its telephony right.
# The WhatsApp state of the table is not listed either: the alert about channels to authorize again names the same channels.
class SuperAdmin::DashboardChecklist
  Result = Struct.new(:rows, :total, :severity, keyword_init: true)

  LIST_LIMIT = SuperAdmin::DashboardAlerts::LIST_LIMIT
  # The kinds of alerts that name accounts (the rest is about the whole platform: one row each)
  ACCOUNT_KINDS = %w[trials_ending trials_expired storage_critical storage_warning reauthorization].freeze
  # The block of the card of an account where the problem is put right (the id of its title)
  ANCHORS = {
    'trials_ending' => 'trial-title', 'trials_expired' => 'plan-title', 'storage_critical' => 'usage-title', 'storage_warning' => 'usage-title'
  }.freeze
  # The problems found in the table of accounts: key, severity, how to tell an account has it and what to say about it.
  # `state` is the key of the line of the table and the value it has when the problem is there.
  MATRIX_KINDS = [
    { key: 'telephony_error', severity: :danger, line: :telephony, state: 'error' },
    { key: 'medelement_error', severity: :danger, line: :medelement, state: 'error' },
    { key: 'failed_messages', severity: :warning, line: :failed_messages },
    { key: 'telephony_unbound', severity: :warning, line: :telephony, state: 'warning' },
    { key: 'medelement_conflicts', severity: :warning, line: :medelement, state: 'warning' }
  ].freeze
  # The order inside one severity: what stops the work of everybody comes first, then what stops one account, then what will
  # stop it soon, then the rest. A kind that is not listed goes last.
  ORDER = %w[
    openrouter_invalid openrouter_expired openrouter_credits_exhausted openrouter_key_limit_exhausted queues_slow reauthorization
    storage_critical telephony_error medelement_error
    openrouter_missing openrouter_unavailable openrouter_credits_low queues_dead queues_unavailable trials_ending trials_expired
    storage_warning failed_messages telephony_unbound medelement_conflicts incomplete matrix_incomplete
  ].freeze
  SEVERITY_RANK = { danger: 0, warning: 1 }.freeze
  # The words of the button of a kind (super_admin.checklist.actions); a kind that is not listed opens the account
  ACTIONS = {
    'trials_ending' => 'trials_ending', 'trials_expired' => 'trials_expired', 'storage_critical' => 'storage', 'storage_warning' => 'storage',
    'queues_slow' => 'queues', 'queues_dead' => 'queues', 'queues_unavailable' => 'queues', 'incomplete' => 'incomplete'
  }.freeze

  def self.build(alerts:, health_accounts:, health_summary:)
    new(alerts, health_accounts, health_summary).result
  end

  def initialize(alerts, health_accounts, health_summary)
    @alerts = Array(alerts)
    @health_accounts = Array(health_accounts)
    @health_summary = health_summary.to_h
  end

  def result
    groups = alert_groups + matrix_groups + health_groups
    ordered = groups.each_with_index.sort_by { |group, index| [rank(group[:severity]), ORDER.index(group[:key]) || ORDER.size, index] }.map(&:first)
    rows = ordered.flat_map { |group| group[:rows] }
    Result.new(rows: rows, total: ordered.sum { |group| group[:count] }, severity: ordered.first&.fetch(:severity))
  end

  private

  def rank(severity) = SEVERITY_RANK.fetch(severity, SEVERITY_RANK.size)

  # ---------------------------------------------------------------- the alerts
  # A group is the rows of one kind of problem and how many problems it counts: { key:, severity:, count:, rows: }
  def alert_groups
    @alerts.map do |alert|
      key = alert[:key].to_s
      severity = alert[:severity].to_sym
      if ACCOUNT_KINDS.include?(key)
        { key: key, severity: severity, count: alert[:count].to_i, rows: account_rows(alert, key, severity) }
      else
        { key: key, severity: severity, count: 1, rows: [platform_row(alert, key, severity)] }
      end
    end
  end

  def account_rows(alert, key, severity)
    items = Array(alert[:items])
    rows = items.map do |item|
      row(key, severity, title: text("rows.#{key}"), subject: item[:label], note: item[:note], label: key_action(key), url: anchored(item[:url], key))
    end
    shown = items.size
    rows << more_row(key, severity, note: text('more', shown: shown, count: alert[:count].to_i), link: alert_link(alert)) if more?(alert, shown)
    rows
  end

  # The list the alert says holds all it found: { url:, label: }, or nil when the alert has no such list
  def alert_link(alert)
    { url: alert[:more_url], label: alert[:more_label] } if alert[:more_url].present?
  end

  def more?(alert, shown)
    alert[:count].to_i > shown && shown.positive? && alert.fetch(:listed, true)
  end

  # One row for a problem of the whole platform: the title and the advice of the alert, the first link of the alert as the button
  def platform_row(alert, key, severity)
    items = Array(alert[:items])
    details = key == 'queues_slow' ? items.map { |item| "#{item[:label]}: #{item[:note]}" } : []
    row(key, severity, title: platform_title(alert, key), subject: text('platform'), hint: alert[:text], details: details,
                       label: key_action(key), url: platform_url(key, items.first))
  end

  # The jobs that did not run are counted in the title: it is the one figure the row has
  def platform_title(alert, key)
    key == 'queues_dead' ? text('rows.queues_dead', count: SuperAdmin::DisplayHelper.format_number(alert[:count])) : alert[:title]
  end

  def platform_url(key, link)
    key == 'incomplete' ? refresh_url : link&.fetch(:url, nil)
  end

  def key_action(key)
    text("actions.#{ACTIONS.fetch(key) { key.start_with?('openrouter_') ? 'openrouter' : 'account' }}")
  end

  def anchored(url, key)
    ANCHORS[key] ? "#{url}##{ANCHORS[key]}" : url
  end

  # ------------------------------------------------- the table of the accounts
  def matrix_groups
    accounts = @health_accounts.reject { |account| account[:status].to_s == 'suspended' }
    MATRIX_KINDS.filter_map { |kind| matrix_group(kind, accounts) }
  end

  def matrix_group(kind, accounts)
    found = accounts.select { |account| problem?(account, kind) }
    return if found.empty?

    found = found.sort_by { |account| -account[:failed_messages].to_i } if kind[:key] == 'failed_messages'
    rows = found.first(LIST_LIMIT).map { |account| matrix_row(account, kind) }
    rows << more_row(kind[:key], kind[:severity], note: text('more', shown: rows.size, count: found.size)) if found.size > rows.size
    { key: kind[:key], severity: kind[:severity], count: found.size, rows: rows }
  end

  def problem?(account, kind)
    line = account[kind[:line]]
    kind[:state] ? line.to_h[:state] == kind[:state] : line.to_i.positive?
  end

  def matrix_row(account, kind)
    key = kind[:key]
    row(key, kind[:severity], title: text("rows.#{key}"), subject: account[:name], note: matrix_note(account, kind), label: text('actions.account'),
                              url: routes.super_admin_account_path(account[:id]))
  end

  # The messages are counted in the note; the other lines say it in their own words (the label of the table)
  def matrix_note(account, kind)
    return account[kind[:line]][:label] unless kind[:key] == 'failed_messages'

    text('notes.failed_messages', days: failed_window, count: SuperAdmin::DisplayHelper.format_number(account[:failed_messages]))
  end

  # The table could not be read at all, or a part of it could not
  def health_groups
    return [matrix_unavailable] if @health_summary.empty?

    sources = Array(@health_summary[:incomplete_sources])
    return [] if sources.empty?

    [{ key: 'matrix_incomplete', severity: :warning, count: 1,
       rows: [row('matrix_incomplete', :warning, title: text('rows.matrix_incomplete'), subject: text('platform'),
                                                 hint: text('hints.matrix_incomplete', sources: sources.join(', ')),
                                                 label: text('actions.incomplete'), url: refresh_url)] }]
  end

  def matrix_unavailable
    { key: 'matrix_incomplete', severity: :warning, count: 1,
      rows: [row('matrix_incomplete', :warning, title: text('rows.matrix_unavailable'), subject: text('platform'),
                                                hint: text('hints.matrix_unavailable'), label: text('actions.incomplete'), url: refresh_url)] }
  end

  # ------------------------------------------------------------------- a row
  # `label` is the word on the button and `url` the place it opens; without a place there is no button. The rest are the fields of the row
  # (title, subject, note, hint, details).
  def row(key, severity, label: nil, url: nil, **fields)
    {
      key: key, severity: severity, title: nil, subject: nil, note: nil, hint: nil, details: [], more: false,
      action: url.present? ? { label: label, url: url } : nil
    }.merge(fields)
  end

  # «Показаны первые 10 из 25» after the rows of one kind, with the link to the whole list when there is one
  def more_row(key, severity, note:, link: nil)
    row(key, severity, note: note, hint: link ? nil : text('more_in_table'), more: true,
                       label: link && (link[:label].presence || text('show_all')), url: link && link[:url])
  end

  def failed_window = SuperAdmin::DisplayHelper.format_wait(SuperAdmin::HealthMatrixService::FAILED_WINDOW)

  def refresh_url = routes.super_admin_root_path(refresh: true)

  def routes = Rails.application.routes.url_helpers

  def text(key, **) = I18n.t("super_admin.checklist.#{key}", locale: :ru, **)
end
