# frozen_string_literal: true

class Captain::Tools::Copilot::GetRecentAccountErrorsService < Captain::Tools::Copilot::BaseObservabilityService
  def self.name
    'get_recent_account_errors'
  end

  description 'List recent account-scoped AI/tool errors with sanitized payload details'
  param :since, type: :string, desc: 'Start time as ISO8601 or Unix timestamp. Defaults to 24 hours ago.', required: false
  param :until, type: :string, desc: 'End time as ISO8601 or Unix timestamp. Defaults to now.', required: false
  param :feature, type: :string, desc: 'Optional LLM feature filter, for example assistant.', required: false
  param :tool_name, type: :string, desc: 'Optional Captain tool name filter.', required: false
  param :limit, type: :number, desc: 'Maximum number of events to return. Capped at 100.', required: false

  def execute(since: nil, feature: nil, tool_name: nil, limit: nil, **kwargs)
    range = time_range(since, kwargs[:until])
    scoped = event_scope(range)
             .where('llm_events.error = ? OR llm_events.tool_failure = ? OR llm_events.status = ?', true, true, 'failed')
    scoped = scoped.for_feature(feature)
    scoped = scoped.for_tool_name(tool_name)
    total_count = scoped.count
    events = scoped.order(created_at: :desc).limit(observability_limit(limit)).map { |event| serialize_llm_event(event) }

    formatted_payload(
      account_id: account.id,
      range: { since: range.begin.iso8601, until: range.end.iso8601 },
      filters: { feature: feature, tool_name: tool_name }.compact,
      total_count: total_count,
      events: events
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
