# frozen_string_literal: true

module Reports
  class CallsQuery
    MAX_LOGICAL_CALLS = 50_000
    MAX_CALL_ROWS = 100
    BOUNDARY_HANDOFF_PADDING = Telephony::CallSession::LogicalGrouping::LOGICAL_GROUP_WINDOW
    CREATED_AT_INDEX_PADDING = 1.day

    attr_reader :account, :params, :date_range

    def initialize(account:, params: {})
      @account = account
      @params = params.to_h.symbolize_keys
      @date_range = DateRange.new(account: account, params: @params)
    end

    def perform
      loaded_groups = load_logical_call_groups
      groups = loaded_groups.first(MAX_LOGICAL_CALLS)
      row_groups = groups.first(MAX_CALL_ROWS)
      preload_row_associations(row_groups.map { |group| group.fetch(:representative) })

      {
        summary: summary_for(groups),
        daily: daily_breakdown(groups),
        rows: call_rows(row_groups),
        coverage: {
          complete: loaded_groups.length <= MAX_LOGICAL_CALLS,
          sampled_calls: groups.length,
          max_logical_calls: MAX_LOGICAL_CALLS
        }
      }
    end

    def meta
      date_range.meta
    end

    private

    def load_logical_call_groups
      scope = account.telephony_call_sessions
      window_from = date_range.from_at - BOUNDARY_HANDOFF_PADDING
      window_until = date_range.until_at + BOUNDARY_HANDOFF_PADDING
      candidates = scope.where(
        created_at: (window_from - CREATED_AT_INDEX_PADDING)..(window_until + CREATED_AT_INDEX_PADDING)
      ).where(
        'COALESCE(started_at, created_at) >= ? AND COALESCE(started_at, created_at) < ?',
        window_from,
        window_until
      )
      groups = Telephony::LogicalCallHistoryQuery.new(
        relation: scope,
        candidate_relation: candidates,
        include_group_siblings: true,
        include_canonical_group_siblings: true,
        limit: MAX_LOGICAL_CALLS + 1
      ).call_with_groups

      groups.select { |group| in_selected_period?(group) }
    end

    def preload_row_associations(sessions)
      return if sessions.empty?

      ActiveRecord::Associations::Preloader.new(
        records: sessions,
        associations: %i[inbox contact]
      ).call
    end

    def summary_for(groups)
      answered = groups.select { |group| answered?(group.fetch(:representative)) }
      inbound_count = groups.count { |group| group.fetch(:representative).direction == 'inbound' }
      outbound_count = groups.count { |group| group.fetch(:representative).direction == 'outbound' }
      answer_rate_percent = groups.empty? ? 0.0 : ((answered.length.to_f / groups.length) * 100).round(1)

      {
        logical_call_count: groups.length,
        answered_count: answered.length,
        unanswered_count: groups.length - answered.length,
        inbound_count: inbound_count,
        outbound_count: outbound_count,
        answer_rate_percent: answer_rate_percent,
        average_answered_duration_seconds: average_duration(answered)
      }
    end

    def daily_breakdown(groups)
      grouped = groups.group_by { |group| local_date_for(group) }

      (date_range.from_date..date_range.to_date).map do |date|
        day_calls = grouped.fetch(date, [])
        answered = day_calls.count { |group| answered?(group.fetch(:representative)) }
        {
          date: date.iso8601,
          logical_call_count: day_calls.length,
          answered_count: answered,
          unanswered_count: day_calls.length - answered
        }
      end
    end

    def call_rows(groups)
      groups.first(MAX_CALL_ROWS).map do |group|
        session = group.fetch(:representative)
        {
          id: session.id,
          started_at: group_started_at(group).iso8601,
          direction: session.direction,
          status: session.canonical_status,
          answered_at: session.answered_at&.iso8601,
          duration_seconds: duration_for(session),
          inbox_id: session.inbox_id,
          inbox_name: session.inbox&.name,
          provider: session.provider,
          contact_id: session.contact_id,
          contact_name: session.contact&.name,
          conversation_id: session.conversation_id,
          from_number: session.from_number,
          to_number: session.to_number
        }
      end
    end

    def answered?(session)
      session.answered_at.present?
    end

    def duration_for(session)
      return session.duration_seconds if session.duration_seconds.present?
      return unless session.answered_at.present? && session.ended_at.present?

      [(session.ended_at - session.answered_at).round, 0].max
    end

    def average_duration(groups)
      durations = groups.filter_map { |group| duration_for(group.fetch(:representative)) }
      return if durations.empty?

      (durations.sum.to_f / durations.length).round(1)
    end

    def in_selected_period?(group)
      started_at = group_started_at(group)
      started_at >= date_range.from_at && started_at < date_range.until_at
    end

    def local_date_for(group)
      group_started_at(group).in_time_zone(date_range.timezone).to_date
    end

    def group_started_at(group)
      group.fetch(:sessions).filter_map { |session| session.started_at || session.created_at }.min
    end
  end
end
