# frozen_string_literal: true

module Reports
  class CallsQuery
    MAX_LOGICAL_CALLS = 1_000
    MAX_CALL_ROWS = 100

    attr_reader :account, :params, :date_range

    def initialize(account:, params: {})
      @account = account
      @params = params.to_h.symbolize_keys
      @date_range = DateRange.new(account: account, params: @params)
    end

    def perform
      queried_groups = logical_call_groups
      in_range_groups = queried_groups.filter_map do |group|
        started_at = logical_started_at(group.fetch(:sessions))
        in_range = started_at && started_at >= date_range.from_at && started_at < date_range.until_at
        next unless in_range

        { group: group, started_at: started_at }
      end
      coverage_complete = queried_groups.size <= MAX_LOGICAL_CALLS
      selected_groups = in_range_groups.first(MAX_LOGICAL_CALLS)
      sessions = selected_groups.map { |item| item.fetch(:group).fetch(:representative) }
      preload_inboxes(sessions)

      {
        summary: summary_for(selected_groups),
        daily_breakdown: daily_breakdown(selected_groups),
        rows: call_rows(selected_groups),
        coverage: {
          complete: coverage_complete,
          limit: MAX_LOGICAL_CALLS,
          sampled_calls: selected_groups.size,
          count_scope: 'logical_calls_by_first_leg_start'
        }
      }
    end

    def meta
      date_range.meta
    end

    private

    def logical_call_groups
      sessions = account.telephony_call_sessions
      range = date_range.from_at...date_range.until_at
      in_range_sessions = sessions.where(started_at: range)
                                 .or(sessions.where(started_at: nil, created_at: range))

      Telephony::LogicalCallHistoryQuery.new(
        relation: sessions,
        candidate_relation: in_range_sessions,
        include_group_siblings: true,
        include_explicit_key_siblings: true,
        limit: MAX_LOGICAL_CALLS + 1
      ).call_with_groups
    end

    def logical_started_at(sessions)
      sessions.filter_map { |session| session.started_at || session.created_at }.min
    end

    def preload_inboxes(sessions)
      ActiveRecord::Associations::Preloader.new(records: sessions, associations: [:inbox]).call
    end

    def answered?(session)
      session.answered_at.present?
    end

    def summary_for(groups)
      representatives = groups.map { |item| item.fetch(:group).fetch(:representative) }
      answered_groups = groups.select do |item|
        answered?(item.fetch(:group).fetch(:representative))
      end
      durations = answered_groups.filter_map do |item|
        duration = item.fetch(:group).fetch(:representative).duration_seconds
        duration.to_i if duration.present?
      end

      {
        logical_call_count: groups.size,
        answered_count: answered_groups.size,
        unanswered_count: groups.size - answered_groups.size,
        inbound_count: representatives.count { |session| session.direction == 'inbound' },
        outbound_count: representatives.count { |session| session.direction == 'outbound' },
        average_answered_duration_seconds: if durations.any?
                                             (durations.sum.to_f / durations.size).round(1)
                                           end
      }
    end

    def daily_breakdown(groups)
      groups.group_by do |item|
        item.fetch(:started_at).in_time_zone(date_range.timezone).to_date
      end.sort.map do |date, items|
        answered_count = items.count do |item|
          answered?(item.fetch(:group).fetch(:representative))
        end
        {
          date: date.iso8601,
          logical_call_count: items.size,
          answered_count: answered_count,
          unanswered_count: items.size - answered_count
        }
      end
    end

    def call_rows(groups)
      groups.sort_by { |item| item.fetch(:started_at) }.reverse.first(MAX_CALL_ROWS).map do |item|
        session = item.fetch(:group).fetch(:representative)
        {
          id: session.id,
          started_at: item.fetch(:started_at).iso8601,
          direction: session.direction,
          status: session.canonical_status,
          answered: answered?(session),
          duration_seconds: answered?(session) ? session.duration_seconds : nil,
          provider: session.provider,
          inbox_name: session.inbox&.name
        }
      end
    end
  end
end
