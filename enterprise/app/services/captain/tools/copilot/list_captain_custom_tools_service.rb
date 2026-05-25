# frozen_string_literal: true

class Captain::Tools::Copilot::ListCaptainCustomToolsService < Captain::Tools::Copilot::CaptainCustomToolAdminTool
  def self.name
    'list_captain_custom_tools'
  end

  description 'List account-scoped Captain custom HTTP tools for AI Admin operations'
  param :query, type: :string, desc: 'Optional search text for title, slug, group, or description', required: false
  param :enabled, type: :boolean, desc: 'Optional enabled status filter', required: false
  param :limit, type: :number, desc: 'Maximum tools to return, capped at 50', required: false

  def execute(query: nil, enabled: nil, limit: nil)
    ensure_account_administrator!

    tools = custom_tools_scope
    tools = tools.where(enabled: cast_boolean(enabled)) unless enabled.nil?
    tools = filter_by_query(tools, query) if query.present?

    formatted_payload(
      action: 'list_captain_custom_tools',
      total_count: tools.count,
      custom_tools: tools.limit(parse_limit(limit, default: 25, max: 50)).map { |custom_tool| custom_tool_payload(custom_tool) }
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def filter_by_query(scope, query)
    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
    scope.where('slug ILIKE :query OR title ILIKE :query OR group_name ILIKE :query OR description ILIKE :query', query: pattern)
  end
end
