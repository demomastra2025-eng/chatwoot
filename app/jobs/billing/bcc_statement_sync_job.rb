# frozen_string_literal: true

class Billing::BccStatementSyncJob < ApplicationJob
  SYNC_KEY = 'bcc_open_api'
  MAX_PAGES = 25

  queue_as :scheduled_jobs

  def perform
    return unless Billing::Config.autobilling_enabled? && Billing::Config.bcc_open_api_configured?

    state = OwnerFinance::SyncState.find_or_initialize_by(sync_key: SYNC_KEY)
    from_time, to_time, initial_cursor = resolve_sync_window(state)
    counts, remaining_cursor = drain_statement_pages(from_time, to_time, initial_cursor)
    persist_sync_progress!(state, from_time, to_time, counts, remaining_cursor)
  rescue Billing::BccOpenApiClient::ApiError => e
    persist_sync_error!(state, e.message)
    Rails.logger.warn("[Billing::BccStatementSyncJob] sync failed: #{e.message}")
  end

  private

  def resolve_sync_window(state)
    saved = state.summary.to_h
    if state.persisted? && saved['next_cursor'].present?
      from_time = parse_iso_time(saved['window_from']) || default_from_time(state)
      to_time = parse_iso_time(saved['window_to']) || Time.current
      [from_time, to_time, saved['next_cursor']]
    else
      [default_from_time(state), Time.current, nil]
    end
  end

  def default_from_time(state)
    (state.last_synced_at || 2.days.ago) - 1.hour
  end

  def drain_statement_pages(from_time, to_time, cursor)
    client = Billing::BccOpenApiClient.new
    counts = { 'fetched' => 0, 'matched' => 0, 'needs_review' => 0, 'pages' => 0 }
    current_cursor = cursor

    MAX_PAGES.times do
      res = client.fetch_credit_transactions(from: from_time, to: to_time, cursor: current_cursor)
      counts['pages'] += 1
      accumulate_transactions!(counts, res[:transactions])
      current_cursor = res[:next_cursor].presence
      break if current_cursor.blank?
    end

    [counts, current_cursor]
  end

  def accumulate_transactions!(counts, rows)
    counts['fetched'] += rows.size
    rows.each do |row|
      event = Billing::PaymentMatcher.new(source: 'bcc_open_api', payload: row).perform
      counts[event.status] = counts[event.status].to_i + 1
    end
  end

  def persist_sync_progress!(state, from_time, to_time, counts, remaining_cursor)
    if remaining_cursor.blank?
      state.update!(
        sync_status: 'ok',
        last_synced_at: to_time,
        summary: counts.merge('next_cursor' => nil, 'synced_at' => to_time.iso8601)
      )
    else
      state.update!(
        sync_status: 'partial',
        last_synced_at: state.last_synced_at,
        summary: counts.merge(
          'next_cursor' => remaining_cursor,
          'window_from' => from_time.iso8601,
          'window_to' => to_time.iso8601
        )
      )
    end
  end

  def persist_sync_error!(state, error_message)
    return unless state

    preserved = state.summary.to_h.slice('next_cursor', 'window_from', 'window_to')
    state.update!(
      sync_status: 'error',
      last_synced_at: state.last_synced_at,
      summary: preserved.merge('error' => error_message, 'failed_at' => Time.current.iso8601)
    )
  end

  def parse_iso_time(raw)
    return nil if raw.blank?

    Time.zone.parse(raw.to_s)
  rescue ArgumentError
    nil
  end
end
