# frozen_string_literal: true

class Captain::Tools::Copilot::GetToolExecutionLogService < Captain::Tools::Copilot::BaseObservabilityService
  def self.name
    'get_tool_execution_log'
  end

  description 'List sanitized account-scoped Captain assistant tool execution events for RCA and debugging'
  param :since, type: :string, desc: 'Start time as ISO8601 or Unix timestamp. Defaults to 24 hours ago.', required: false
  param :until, type: :string, desc: 'End time as ISO8601 or Unix timestamp. Defaults to now.', required: false
  param :tool_id, type: :string, desc: 'Optional Captain tool ID filter.', required: false
  param :conversation_display_id, type: :number, desc: 'Optional conversation display ID filter.', required: false
  param :failed_only, type: :boolean, desc: 'When true, return only failed tool executions.', required: false
  param :limit, type: :number, desc: 'Maximum number of entries to return. Capped at 100.', required: false

  def execute(since: nil, tool_id: nil, conversation_display_id: nil, failed_only: false, limit: nil, **kwargs)
    range = time_range(since, kwargs[:until])
    scoped = tool_execution_events(range)
    scoped = scoped.for_tool_name(tool_id)
    scoped = scoped.for_conversation_display_id(conversation_display_id)
    scoped = failed_tool_events(scoped) if cast_boolean(failed_only)

    formatted_payload(
      account_id: account.id,
      range: { since: range.begin.iso8601, until: range.end.iso8601 },
      filters: tool_log_filters(tool_id, conversation_display_id, failed_only),
      total_count: scoped.count,
      entries: scoped.reorder(created_at: :desc, id: :desc)
                     .limit(observability_limit(limit))
                     .map { |event| serialize_tool_execution_event(event) }
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def tool_log_filters(tool_id, conversation_display_id, failed_only)
    {
      tool_id: tool_id,
      conversation_display_id: conversation_display_id,
      failed_only: cast_boolean(failed_only)
    }.compact
  end
end
