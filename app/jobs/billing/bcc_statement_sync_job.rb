# frozen_string_literal: true

class Billing::BccStatementSyncJob < ApplicationJob
  SYNC_KEY = 'bcc_open_api'

  queue_as :scheduled_jobs

  def perform
    return unless Billing::Config.autobilling_enabled? && Billing::Config.bcc_open_api_configured?

    state = OwnerFinance::SyncState.find_by(sync_key: SYNC_KEY)
    result = fetch_statement_batch(state)
    counts = process_transactions(result[:transactions])
    OwnerFinance::SyncState.record!(
      SYNC_KEY,
      status: 'ok',
      summary: counts.merge('next_cursor' => result[:next_cursor], 'synced_at' => Time.current.iso8601)
    )
  rescue Billing::BccOpenApiClient::ApiError => e
    OwnerFinance::SyncState.record!(SYNC_KEY, status: 'error', summary: { 'error' => e.message })
    Rails.logger.warn("[Billing::BccStatementSyncJob] sync failed: #{e.message}")
  end

  private

  def fetch_statement_batch(state)
    from_time = (state&.last_synced_at || 2.days.ago) - 1.hour
    cursor = state&.summary.to_h['next_cursor']
    Billing::BccOpenApiClient.new.fetch_credit_transactions(from: from_time, to: Time.current, cursor: cursor)
  end

  def process_transactions(rows)
    counts = { 'fetched' => rows.size, 'matched' => 0, 'needs_review' => 0 }
    rows.each do |row|
      event = Billing::PaymentMatcher.new(source: 'bcc_open_api', payload: row).perform
      counts[event.status] = counts[event.status].to_i + 1
    end
    counts
  end
end
