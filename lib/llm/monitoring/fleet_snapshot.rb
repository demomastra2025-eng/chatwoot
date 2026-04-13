# frozen_string_literal: true

class Llm::Monitoring::FleetSnapshot
  DEFAULT_WINDOW = 30.days
  TOP_ACCOUNT_LIMIT = 12

  def initialize(scope: LlmEvent.all, date_range: nil, now: Time.current)
    @scope = scope.respond_to?(:except) ? scope.except(:order) : scope
    @date_range = date_range
    @now = now
  end

  def call
    scoped = @scope.for_date_range(effective_range)

    {
      date_range: effective_range,
      snapshot: Llm::Monitoring::MetricsSnapshot.new(scope: scoped).call,
      time_series: Llm::Monitoring::TimeSeriesSnapshot.new(scope: scoped, date_range: effective_range).call,
      top_accounts: top_accounts(scoped)
    }
  end

  private

  def effective_range
    @effective_range ||= @date_range || ((@now - DEFAULT_WINDOW)..@now)
  end

  def top_accounts(scoped)
    rows = scoped
           .group(:account_id)
           .pluck(
             :account_id,
             Arel.sql('COUNT(*)'),
             Arel.sql("SUM(CASE WHEN event_name = 'llm.chat.complete' THEN 1 ELSE 0 END)"),
             Arel.sql("SUM(CASE WHEN error = TRUE THEN 1 ELSE 0 END)"),
             Arel.sql('SUM(COALESCE(estimated_cost, 0))'),
             Arel.sql('MAX(created_at)')
           )
           .sort_by { |(_, _events, _requests, errors, cost, last_event_at)| [-cost.to_f, -errors.to_i, -(last_event_at&.to_i || 0)] }
           .first(TOP_ACCOUNT_LIMIT)

    accounts = Account.where(id: rows.map(&:first).compact).pluck(:id, :name).to_h

    rows.map do |account_id, total_events, request_count, error_count, estimated_cost, last_event_at|
      {
        account_id: account_id,
        account_name: accounts[account_id] || 'Unknown account',
        total_events: total_events.to_i,
        request_count: request_count.to_i,
        error_count: error_count.to_i,
        estimated_cost: estimated_cost.to_f.round(8),
        last_event_at: last_event_at
      }
    end
  end
end
