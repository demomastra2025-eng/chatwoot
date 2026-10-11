# frozen_string_literal: true

class Reports::AiAgentsQuery
  class InvalidAssistantFilter < ArgumentError; end

  METRIC_KEYS = %i[message_count conversation_count outcome_count completion_count handoff_count classification_counts].freeze
  MAX_ASSISTANT_ID = (2**63) - 1

  attr_reader :account, :date_range, :assistant_id

  def initialize(account:, params: {})
    @account = account
    values = params.to_h.symbolize_keys
    @date_range = Reports::DateRange.new(account: account, params: values)
    @assistant_id = resolve_assistant_id(values[:assistant_id])
  end

  def perform
    rows = Reports::AiAgentEventsQuery.new(account: account, date_range: date_range, assistant_id: assistant_id).perform
    metrics, reasons = rows.partition { |row| row[:kind] == 'metric' }.map { |group| group.pluck(:data) }
    {
      totals: metric_values(metrics.find { |row| row[:row_type] == 'total' }),
      series: daily_series(metrics),
      agents: available_agents,
      agent_breakdown: agent_breakdown(metrics),
      reasons: reasons.sort_by { |row| [-row[:count], row[:type], row[:assistant_id], row[:reason_id]] },
      coordination: Reports::AiAgentTransfersQuery.new(account: account, date_range: date_range,
                                                        assistant_id: assistant_id).perform,
      availability: unavailable_metrics
    }
  end

  def meta
    date_range.meta.merge(assistant_id: assistant_id)
  end

  private

  def resolve_assistant_id(value)
    return if value.nil? || value.to_s.blank?

    id = value.to_s.to_i if value.to_s.match?(/\A[1-9]\d*\z/)
    return id if id && id <= MAX_ASSISTANT_ID && Captain::Assistant.where(account_id: account.id, id: id).exists?

    raise InvalidAssistantFilter, 'assistant_id must identify an assistant in this account'
  end

  def available_agents
    Captain::Assistant.where(account_id: account.id).order(:name, :id).pluck(:id, :name, :active).map do |id, name, active|
      { id: id, name: name, active: active }
    end
  end

  def metric_values(row)
    return empty_metrics unless row

    row.slice(*METRIC_KEYS).merge(classification_counts: row.fetch(:classification_counts).symbolize_keys)
  end

  def empty_metrics
    METRIC_KEYS.index_with(0).merge(classification_counts: Reports::AiAgentEventsQuery::CLASSIFICATION_STATES.index_with(0).symbolize_keys)
  end

  def daily_series(metrics)
    by_date = metrics.select { |row| row[:row_type] == 'series' }.index_by { |row| row[:date] }
    (date_range.from_date..date_range.to_date).map do |date|
      { date: date.iso8601 }.merge(metric_values(by_date[date.iso8601]))
    end
  end

  def agent_breakdown(metrics)
    metrics.select { |row| row[:row_type] == 'agent' }
           .sort_by { |row| [-row[:message_count] - row[:outcome_count], row[:assistant_id]] }
           .map { |row| row.slice(:assistant_id, :name, :active).merge(metric_values(row)) }
  end

  def unavailable_metrics
    {
      latency: { available: false, reason: 'native_attribution_unavailable' },
      cost: { available: false, reason: 'native_attribution_unavailable' }
    }
  end
end
