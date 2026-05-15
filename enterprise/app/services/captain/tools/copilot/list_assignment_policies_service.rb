# frozen_string_literal: true

class Captain::Tools::Copilot::ListAssignmentPoliciesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_assignment_policies'
  end

  description 'List account assignment policies with routing settings and attached inbox IDs'
  param :query, type: :string, desc: 'Optional partial match against policy name or description', required: false
  param :enabled, type: :boolean, desc: 'Optional enabled filter', required: false
  param :limit, type: :number, desc: 'Maximum number of policies to return', required: false

  def execute(query: nil, enabled: nil, limit: nil)
    policies = filtered_policies(query: query, enabled: enabled)

    formatted_payload(
      filters: { query: query, enabled: enabled }.compact,
      total_count: policies.count,
      policies: policies.limit(parse_limit(limit)).map { |policy| policy_payload(policy) },
      assignment_orders: AssignmentPolicy.assignment_orders.keys,
      conversation_priorities: AssignmentPolicy.conversation_priorities.keys
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def filtered_policies(query:, enabled:)
    scope = account.assignment_policies.includes(:inboxes).order(:name, :id)
    scope = scope.where('LOWER(name) ILIKE :query OR LOWER(description) ILIKE :query', query: "%#{query.to_s.downcase}%") if query.present?
    scope = scope.where(enabled: cast_boolean(enabled)) unless enabled.nil?
    scope
  end

  def policy_payload(policy)
    {
      id: policy.id,
      name: policy.name,
      description: policy.description,
      enabled: policy.enabled,
      assignment_order: policy.assignment_order,
      conversation_priority: policy.conversation_priority,
      fair_distribution_limit: policy.fair_distribution_limit,
      fair_distribution_window: policy.fair_distribution_window,
      inbox_ids: policy.inboxes.map(&:id),
      created_at: policy.created_at&.iso8601,
      updated_at: policy.updated_at&.iso8601
    }.compact
  end
end
