# frozen_string_literal: true

class Llm::Monitoring::EventsQuery
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100

  def initialize(scope: LlmEvent.all, params: {}, date_range: nil)
    @scope = scope
    @params = params.to_h.with_indifferent_access
    @date_range = date_range
  end

  def snapshot
    Llm::Monitoring::MetricsSnapshot.new(scope: filtered_scope).call
  end

  def time_series
    Llm::Monitoring::TimeSeriesSnapshot.new(
      scope: filtered_scope,
      date_range: @date_range
    ).call
  end

  def release_gate(account: nil, preferences: nil)
    Llm::Monitoring::ReleaseGate.new(
      scope: scoped_without_date_range,
      date_range: @date_range,
      config: Llm::RuntimePolicy.release_gate_config(account: account, preferences: preferences)
    ).call
  end

  def runtime_health(account: nil, snapshot: nil, release_gate: nil)
    Llm::Monitoring::RuntimeHealth.new(
      account: account,
      scope: filtered_scope,
      date_range: @date_range,
      snapshot: snapshot || self.snapshot,
      release_gate: release_gate
    ).call
  end

  def performance_budget
    Llm::Monitoring::PerformanceBudgetSnapshot.new(scope: filtered_scope).call
  end

  def paginated_events
    @paginated_events ||= filtered_scope.page(current_page).per(per_page)
  end

  def meta
    {
      count: paginated_events.total_count,
      current_page: current_page,
      per_page: per_page,
      applied_filters: applied_filters
    }
  end

  def export_events(limit: nil)
    scoped = filtered_scope
    limit.present? ? scoped.limit(limit) : scoped
  end

  def export_count
    filtered_scope.count
  end

  private

  def filtered_scope
    @filtered_scope ||= scoped_without_date_range
                        .for_date_range(@date_range)
                        .order(created_at: :desc)
  end

  def scoped_without_date_range
    @scoped_without_date_range ||= @scope
                                   .for_feature(@params[:feature])
                                   .for_model(@params[:model])
                                   .for_event_name(@params[:event_name])
                                   .for_runtime_mode(@params[:runtime_mode])
                                   .for_status(@params[:status])
                                   .for_trace_id(@params[:trace_id])
                                   .for_session_id(@params[:session_id])
                                   .for_project_case(project_case_id)
                                   .for_error_code(error_code)
                                   .for_flag(@params[:flag])
                                   .for_assistant(@params[:assistant_id])
                                   .for_conversation(@params[:conversation_id])
                                   .for_conversation_display_id(@params[:conversation_display_id])
                                   .for_copilot_thread(@params[:copilot_thread_id])
                                   .for_tool_name(@params[:tool_name])
                                   .for_schema_name(@params[:schema_name])
  end

  def current_page
    page = @params[:page].to_i
    page.positive? ? page : 1
  end

  def per_page
    requested = @params[:per_page].to_i
    return DEFAULT_PER_PAGE unless requested.positive?

    [requested, MAX_PER_PAGE].min
  end

  def applied_filters
    {
      feature: @params[:feature],
      model: @params[:model],
      event_name: @params[:event_name],
      runtime_mode: @params[:runtime_mode],
      status: @params[:status],
      trace_id: @params[:trace_id],
      session_id: @params[:session_id],
      project_case_id: project_case_id,
      error_code: error_code,
      flag: @params[:flag],
      assistant_id: integer_filter(:assistant_id),
      conversation_id: integer_filter(:conversation_id),
      conversation_display_id: integer_filter(:conversation_display_id),
      copilot_thread_id: integer_filter(:copilot_thread_id),
      tool_name: @params[:tool_name],
      schema_name: @params[:schema_name],
      since: @params[:since],
      until: @params[:until]
    }.compact
  end

  def project_case_id
    Llm::ProjectCaseId.normalize(@params[:project_case_id])
  end

  def error_code
    Llm::EventCode.normalize(@params[:error_code])
  end

  def integer_filter(key)
    Integer(@params[key]) if @params[key].present?
  rescue ArgumentError, TypeError
    nil
  end
end
