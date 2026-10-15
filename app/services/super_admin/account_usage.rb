# frozen_string_literal: true

# The limits and spend of one clinic as rows for the clinic card: what is used, what the limit is and how full it is.
# It reads `Account#account_usage_overview` (computed once) and puts a Russian name and hint on every limit.
#
#   usage = SuperAdmin::AccountUsage.new(account)
#   usage.rows.each { |row| row.label, row.consumed, row.total, row.unlimited, row.percent, row.tone }
class SuperAdmin::AccountUsage
  # percent of the limit at which the meter turns amber / red (the storage alerts use the same thresholds)
  WARNING_PERCENT = 80
  CRITICAL_PERCENT = 95

  Row = Struct.new(:key, :label, :hint, :consumed, :total, :unlimited, :bytes, :percent, :tone, keyword_init: true) do
    # A limit of 0 forbids the action altogether
    def blocked?
      !unlimited && total.to_i.zero?
    end
  end

  # [row key, key of the limit in Account#limits, where the numbers sit in account_usage_overview, bytes?]
  DEFINITIONS = [
    [:agents, 'agents', %i[agents], false],
    [:inboxes, 'inboxes', %i[inboxes], false],
    [:conversations, 'conversations', %i[conversations], false],
    [:non_web_inboxes, 'non_web_inboxes', %i[non_web_inboxes], false],
    [:storage, 'storage_bytes', %i[storage], true],
    [:captain_responses, 'captain_responses', %i[captain responses], false],
    [:captain_documents, 'captain_documents', %i[captain documents], false],
    [:captain_tokens, 'captain_tokens', %i[captain tokens], false],
    [:emails, 'emails', %i[emails], false]
  ].freeze

  # `overview:` is an already computed Account#account_usage_overview (the field of the form has one)
  def initialize(account = nil, overview: nil)
    @account = account
    @overview = overview&.with_indifferent_access
  end

  def rows
    @rows ||= DEFINITIONS.filter_map { |key, limit_key, path, bytes| build_row(key, limit_key, overview.dig(*path), bytes) }
  end

  def row(key)
    rows.find { |candidate| candidate.key == key.to_sym }
  end

  # The summary of Account#account_usage_overview, read once
  def overview
    @overview ||= (@account.account_usage_overview || {}).with_indifferent_access
  end

  private

  def build_row(key, limit_key, summary, bytes)
    return if summary.blank?

    total = summary[:total_count].to_i
    consumed = summary[:consumed].to_i
    # A plan writes "no limit" as ChatwootApp.max_limit, which the code treats as no limit too
    unlimited = summary[:unlimited] || (!bytes && total == ChatwootApp.max_limit.to_i) ? true : false
    percent = percent_of(consumed, total, unlimited)

    Row.new(
      key: key, label: I18n.t("super_admin.limits.#{limit_key}.label"), hint: I18n.t("super_admin.limits.#{limit_key}.hint"),
      consumed: consumed, total: total, unlimited: unlimited, bytes: bytes, percent: percent, tone: tone_for(percent, total, unlimited)
    )
  end

  def percent_of(consumed, total, unlimited)
    return if unlimited || total <= 0

    (consumed.to_f / total * 100).round(1)
  end

  def tone_for(percent, total, unlimited)
    return :idle if unlimited
    return :bad if total <= 0
    return :bad if percent >= CRITICAL_PERCENT
    return :warn if percent >= WARNING_PERCENT

    :good
  end
end
