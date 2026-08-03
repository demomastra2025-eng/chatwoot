class Captain::Tools::Copilot::SearchLinearIssuesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_linear_issues'
  end

  description 'Search Linear issues by a search term'
  param :term, type: :string, desc: 'The search term to find Linear issues', required: true
  param :limit, type: :number, desc: 'Maximum number of issues to return', required: false

  def execute(term:, limit: nil)
    return tool_failure('Linear integration is not enabled') unless active?

    linear_service = Integrations::Linear::ProcessorService.new(account: account)
    result = linear_service.search_issue(term)
    return result[:error] if result[:error]

    issues = Array(result[:data])
    total_count = issues.length
    records = issues.first(parse_limit(limit)).map { |issue| issue_payload(issue) }

    formatted_payload(
      filters: { term: term },
      total_count: total_count,
      issues: records
    )
  end

  def active?
    @user.present? && account.hooks.exists?(app_id: 'linear')
  end

  private

  def inactive_tool_error_message
    'Linear integration is not enabled'
  end

  def issue_payload(issue)
    {
      id: issue['id'],
      title: issue['title'],
      description: issue['description'],
      state: issue.dig('state', 'name'),
      priority: format_priority(issue['priority']),
      assignee_name: issue.dig('assignee', 'name')
    }.compact
  end

  def format_priority(priority)
    return 'No priority' if priority.nil?

    case priority
    when 0 then 'No priority'
    when 1 then 'Urgent'
    when 2 then 'High'
    when 3 then 'Medium'
    when 4 then 'Low'
    else 'Unknown'
    end
  end
end
