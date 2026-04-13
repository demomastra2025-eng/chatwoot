# frozen_string_literal: true

require 'csv'

class Api::V1::Accounts::Captain::ObservabilityController < Api::V1::Accounts::BaseController
  include DateRangeHelper

  MAX_EXPORT_ROWS = 5_000

  before_action :check_admin_authorization?

  def show
    query = events_query
    release_gate = query.release_gate(account: Current.account)
    alerts = Llm::Monitoring::AlertEvaluator.new(release_gate_report: release_gate).call

    render json: {
      snapshot: query.snapshot,
      time_series: query.time_series,
      release_gate: release_gate,
      alerts: alerts,
      alert_delivery_state: Llm::Monitoring::AlertNotifier.state_for(Current.account),
      preferences: observability_preferences,
      payload: query.paginated_events.map { |event| serialize_event(event) },
      meta: query.meta
    }
  end

  def metrics
    query = events_query
    release_gate = query.release_gate(account: Current.account)
    alerts = Llm::Monitoring::AlertEvaluator.new(release_gate_report: release_gate).call

    render plain: Llm::Monitoring::PrometheusExporter.new(
      snapshot: query.snapshot,
      release_gate: release_gate,
      alerts: alerts,
      labels: { account_id: Current.account.id }
    ).call,
           content_type: 'text/plain; version=0.0.4'
  end

  def release_check
    report = Llm::ReleaseCheck::Runner.new(
      account: Current.account,
      date_range: effective_range,
      filters: release_check_filters,
      evaluation_model: params[:eval_model].presence,
      include_live_evals: ActiveModel::Type::Boolean.new.cast(params[:include_live]) == true
    ).call

    render json: report.to_h
  end

  def export
    query = events_query
    total_count = query.export_count
    events = query.export_events(limit: MAX_EXPORT_ROWS)
    payload = events.map { |event| serialize_event(event) }
    truncated = total_count > MAX_EXPORT_ROWS
    requested_format = params[:export_format].presence || params[:format].presence
    format = request.format.csv? || requested_format.to_s.downcase == 'csv' ? 'csv' : 'json'

    send_data(
      format == 'csv' ? csv_export(payload) : json_export(query, payload, total_count:, truncated:),
      filename: export_filename(format),
      type: format == 'csv' ? 'text/csv; charset=utf-8' : 'application/json'
    )
  end

  private

  def events_query
    @events_query ||= Llm::Monitoring::EventsQuery.new(
      scope: Current.account.llm_events,
      params: observability_params,
      date_range: effective_range
    )
  end

  def observability_params
    params.permit(
      :page,
      :per_page,
      :feature,
      :model,
      :event_name,
      :runtime_mode,
      :status,
      :trace_id,
      :session_id,
      :flag,
      :assistant_id,
      :conversation_id,
      :conversation_display_id,
      :copilot_thread_id,
      :tool_name,
      :schema_name,
      :since,
      :until
    )
  end

  def release_check_filters
    observability_params.to_h.except('page', 'per_page', 'since', 'until').compact_blank
  end

  def effective_range
    range || Llm::Monitoring::AccountPreferences.default_date_range(account: Current.account)
  end

  def observability_preferences
    Llm::Monitoring::AccountPreferences.for(Current.account)
  end

  def export_filename(format)
    timestamp = Time.current.utc.strftime('%Y%m%d-%H%M%S')
    "captain-observability-#{Current.account.id}-#{timestamp}.#{format}"
  end

  def json_export(query, payload, total_count:, truncated:)
    JSON.pretty_generate(
      exported_at: Time.current.iso8601,
      account_id: Current.account.id,
      meta: query.meta.merge(
        exported_count: payload.size,
        total_matching_count: total_count,
        truncated: truncated
      ),
      payload: payload
    )
  end

  def csv_export(payload)
    CSV.generate(headers: true) do |csv|
      csv << %w[
        id created_at event_name feature runtime_mode status reason provider model
        tool_name schema_name request_id trace_id trace_name root_span_id span_id parent_span_id span_kind span_name moderation_stage safety_rule failure_mode flagged_categories current_agent channel_type source session_id assistant_id
        conversation_id conversation_display_id copilot_thread_id prompt_tokens
        completion_tokens total_tokens duration_ms estimated_cost blocked
        moderation_skipped schema_invalid tool_failure error
      ]

      payload.each do |event|
        csv << [
          event[:id],
          event[:created_at],
          event[:event_name],
          event[:feature],
          event[:runtime_mode],
          event[:status],
          event[:reason],
          event[:provider],
          event[:model],
          event[:tool_name],
          event[:schema_name],
          event[:request_id],
          event[:trace_id],
          event[:trace_name],
          event[:root_span_id],
          event[:span_id],
          event[:parent_span_id],
          event[:span_kind],
          event[:span_name],
          event[:moderation_stage],
          event[:safety_rule],
          event[:failure_mode],
          Array(event[:flagged_categories]).join('|'),
          event[:current_agent],
          event[:channel_type],
          event[:source],
          event[:session_id],
          event[:assistant_id],
          event[:conversation_id],
          event[:conversation_display_id],
          event[:copilot_thread_id],
          event[:prompt_tokens],
          event[:completion_tokens],
          event[:total_tokens],
          event[:duration_ms],
          event[:estimated_cost],
          event[:blocked],
          event[:moderation_skipped],
          event[:schema_invalid],
          event[:tool_failure],
          event[:error]
        ]
      end
    end
  end

  def serialize_event(event)
    {
      id: event.id,
      created_at: event.created_at,
      event_name: event.event_name,
      feature: event.feature,
      runtime_mode: event.runtime_mode,
      status: event.status,
      reason: event.reason,
      provider: event.provider,
      model: event.model,
      tool_name: event.tool_name,
      schema_name: event.schema_name,
      request_id: event.request_id,
      trace_id: event.trace_id.presence || event.payload['trace_id'],
      trace_name: event.payload['trace_name'],
      root_span_id: event.payload['root_span_id'],
      span_id: event.payload['span_id'],
      parent_span_id: event.payload['parent_span_id'],
      span_kind: event.payload['span_kind'],
      span_name: event.payload['span_name'],
      current_agent: event.current_agent,
      channel_type: event.channel_type,
      source: event.source,
      session_id: event.session_id,
      assistant_id: event.assistant_id,
      conversation_id: event.conversation_id,
      conversation_display_id: event.conversation_display_id,
      copilot_thread_id: event.copilot_thread_id,
      moderation_stage: event.payload['stage'],
      safety_rule: event.payload['rule'],
      failure_mode: event.payload['failure_mode'],
      flagged_categories: event.payload['flagged_categories'],
      prompt_tokens: event.prompt_tokens,
      completion_tokens: event.completion_tokens,
      total_tokens: event.total_tokens,
      duration_ms: event.duration_ms,
      estimated_cost: event.estimated_cost,
      blocked: event.blocked,
      moderation_skipped: event.moderation_skipped,
      schema_invalid: event.schema_invalid,
      tool_failure: event.tool_failure,
      error: event.error,
      details: event.payload
    }
  end
end
