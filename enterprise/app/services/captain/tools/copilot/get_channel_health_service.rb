# frozen_string_literal: true

class Captain::Tools::Copilot::GetChannelHealthService < Captain::Tools::Copilot::BaseObservabilityService
  def self.name
    'get_channel_health'
  end

  description 'Get account-scoped inbox/channel health from messages and delivery failures without exposing provider secrets'
  param :inbox_id, type: :integer, desc: 'Optional inbox ID to inspect. Defaults to all active account inboxes.', required: false
  param :since, type: :string, desc: 'Start time as ISO8601 or Unix timestamp. Defaults to 24 hours ago.', required: false
  param :until, type: :string, desc: 'End time as ISO8601 or Unix timestamp. Defaults to now.', required: false
  param :limit, type: :number, desc: 'Maximum recent failures per inbox. Capped at 20.', required: false

  def execute(inbox_id: nil, since: nil, limit: nil, **kwargs)
    range = time_range(since, kwargs[:until])
    inboxes = scoped_inboxes(inbox_id)

    formatted_payload(
      account_id: account.id,
      range: { since: range.begin.iso8601, until: range.end.iso8601 },
      channels: inboxes.map { |inbox| channel_payload(inbox, range, observability_limit(limit, default: 5, max: 20)) }
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def scoped_inboxes(inbox_id)
    scope = account.inboxes.active.order(:id)
    inbox_id.present? ? scope.where(id: inbox_id) : scope
  end

  def channel_payload(inbox, range, failure_limit)
    messages = inbox.messages.where(account_id: account.id, created_at: range)
    failed_outgoing = messages.outgoing.failed.reorder(created_at: :desc, id: :desc)
    failed_outgoing_count = failed_outgoing.count

    {
      inbox_id: inbox.id,
      inbox_name: inbox.name,
      channel_type: inbox.channel_type,
      status: failed_outgoing_count.positive? ? 'degraded' : 'healthy',
      total_messages: messages.count,
      incoming_count: messages.incoming.count,
      outgoing_count: messages.outgoing.count,
      failed_outgoing_count: failed_outgoing_count,
      recent_failures: failed_outgoing.limit(failure_limit).map { |message| failure_payload(message) }
    }
  end

  def failure_payload(message)
    {
      message_id: message.id,
      conversation_id: message.conversation_id,
      conversation_display_id: message.conversation&.display_id,
      created_at: message.created_at&.iso8601,
      external_error: external_error_for(message)
    }.compact
  end
end
