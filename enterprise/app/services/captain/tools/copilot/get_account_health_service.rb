# frozen_string_literal: true

class Captain::Tools::Copilot::GetAccountHealthService < Captain::Tools::Copilot::BaseObservabilityService
  def self.name
    'get_account_health'
  end

  description 'Get an account-scoped health snapshot for Captain, channels, and message delivery without exposing raw logs or secrets'
  param :since, type: :string, desc: 'Start time as ISO8601 or Unix timestamp. Defaults to 24 hours ago.', required: false
  param :until, type: :string, desc: 'End time as ISO8601 or Unix timestamp. Defaults to now.', required: false

  def execute(since: nil, **kwargs)
    range = time_range(since, kwargs[:until])
    query = observability_events(range: range)
    snapshot = query.snapshot
    failed_outgoing_count = failed_outgoing_messages(range).count
    status = health_status(
      error_count: snapshot[:error_count],
      tool_failure_count: snapshot[:tool_failure_count],
      failed_outgoing_count: failed_outgoing_count
    )

    formatted_payload(
      account_id: account.id,
      status: status,
      range: { since: range.begin.iso8601, until: range.end.iso8601 },
      snapshot: snapshot,
      delivery: delivery_snapshot(range, failed_outgoing_count),
      channels: channel_snapshot,
      recommendations: recommendations(snapshot, failed_outgoing_count)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def delivery_snapshot(range, failed_outgoing_count)
    messages = account.messages.where(created_at: range)

    {
      total_messages: messages.count,
      outgoing_count: messages.outgoing.count,
      failed_outgoing_count: failed_outgoing_count
    }
  end

  def channel_snapshot
    active_inboxes = account.inboxes.active

    {
      active_inbox_count: active_inboxes.count,
      channel_types: active_inboxes.group(:channel_type).count
    }
  end

  def recommendations(snapshot, failed_outgoing_count)
    notes = []
    notes << 'Review recent failed AI/tool events with get_recent_account_errors.' if snapshot[:error_count].to_i.positive?
    notes << 'Inspect failing Captain tool traces with trace_ai_response.' if snapshot[:tool_failure_count].to_i.positive?
    notes << 'Trace failed outbound delivery with trace_message_delivery or get_channel_health.' if failed_outgoing_count.positive?
    notes << 'No recent account-level errors detected.' if notes.empty?
    notes
  end
end
