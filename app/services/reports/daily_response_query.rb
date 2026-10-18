# frozen_string_literal: true

module Reports
  class DailyResponseQuery
    attr_reader :account, :params, :date_range

    def initialize(account:, params: {})
      @account = account
      @params = params.to_h.symbolize_keys
      @date_range = DateRange.new(account: account, params: @params)
    end

    def perform
      first_responses = load_earliest_first_responses
      daily_conversations = group_conversations_by_day(first_responses)
      daily_replies = group_reply_times_by_day

      rows = (date_range.from_date..date_range.to_date).map do |day|
        conv_stats = daily_conversations[day] || { total: 0, answered: 0, first_response_values: [] }
        reply_values = daily_replies[day] || []
        total = conv_stats[:total]
        answered = conv_stats[:answered]
        unanswered = total - answered
        share = total.positive? ? (answered.to_f / total * 100).round(1) : nil

        {
          date: day.iso8601,
          iso_weekday: day.cwday,
          total: total,
          answered: answered,
          unanswered: unanswered,
          answered_share_percent: share,
          avg_first_response_seconds: average(conv_stats[:first_response_values]),
          avg_reply_wait_seconds: average(reply_values),
          reply_events_count: reply_values.size
        }
      end

      all_first_response_values = daily_conversations.values.flat_map { |item| item[:first_response_values] }
      all_reply_values = daily_replies.values.flatten
      total_sum = rows.sum { |row| row[:total] }
      answered_sum = rows.sum { |row| row[:answered] }
      unanswered_sum = total_sum - answered_sum

      {
        summary: {
          days: rows.size,
          total: total_sum,
          answered: answered_sum,
          unanswered: unanswered_sum,
          answered_share_percent: total_sum.positive? ? (answered_sum.to_f / total_sum * 100).round(1) : 0.0,
          avg_first_response_seconds: average(all_first_response_values),
          avg_reply_wait_seconds: average(all_reply_values)
        },
        rows: rows
      }
    end

    def meta
      date_range.meta
    end

    private

    def timezone
      date_range.timezone
    end

    def load_earliest_first_responses
      events = account.reporting_events
                      .where(
                        name: 'first_response',
                        event_end_time: date_range.from_at...date_range.until_at
                      )
                      .where.not(conversation_id: nil)
                      .order(:conversation_id, :event_end_time, :id)
                      .pluck(:conversation_id, :event_end_time, :value)

      earliest = {}
      events.each do |conv_id, event_end_time, value|
        next if earliest.key?(conv_id)

        earliest[conv_id] = {
          date: event_end_time.in_time_zone(timezone).to_date,
          value: value.to_f
        }
      end
      earliest
    end

    def group_conversations_by_day(first_responses)
      convs = account.conversations
                     .where(created_at: date_range.from_at...date_range.until_at)
                     .pluck(:id, :created_at)

      grouped = {}
      convs.each do |conv_id, created_at|
        day = created_at.in_time_zone(timezone).to_date
        entry = (grouped[day] ||= { total: 0, answered: 0, first_response_values: [] })
        entry[:total] += 1

        fr = first_responses[conv_id]
        next unless fr && fr[:date] == day

        entry[:answered] += 1
        entry[:first_response_values] << fr[:value] if fr[:value]
      end
      grouped
    end

    def group_reply_times_by_day
      events = account.reporting_events
                      .where(
                        name: 'reply_time',
                        event_end_time: date_range.from_at...date_range.until_at
                      )
                      .pluck(:event_end_time, :value)

      grouped = Hash.new { |h, k| h[k] = [] }
      events.each do |event_end_time, value|
        next if event_end_time.nil? || value.nil?

        day = event_end_time.in_time_zone(timezone).to_date
        grouped[day] << value.to_f
      end
      grouped
    end

    def average(values)
      return nil if values.empty?

      (values.sum.to_f / values.size).round(1)
    end
  end
end
