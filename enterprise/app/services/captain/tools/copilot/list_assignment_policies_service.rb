# frozen_string_literal: true

class Captain::Tools::Copilot::ListAssignmentPoliciesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_assignment_policies'
  end

  description 'List account assignment policies with routing settings and attached inbox IDs for account administrators'
  param :query, type: :string, desc: 'Optional partial match against assignment policy name or description', required: false
  param :enabled, type: :boolean, desc: 'Optional enabled-state filter', required: false
  param :limit, type: :number, desc: 'Maximum number of assignment policies to return', required: false

  def execute(query: nil, enabled: nil, limit: nil)
    ensure_account_administrator!

    policies = filtered_policies(query: query, enabled: enabled)
    records = policies.limit(parse_limit(limit)).map { |assignment_policy| assignment_policy_payload(assignment_policy) }

    formatted_payload(
      filters: { query: query, enabled: enabled }.compact,
      total_count: policies.count,
      policies: records,
      assignment_policies: records,
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

  def assignment_policy_payload(assignment_policy)
    inboxes = account_inboxes_for(assignment_policy)

    {
      id: assignment_policy.id,
      name: assignment_policy.name,
      description: assignment_policy.description,
      enabled: assignment_policy.enabled,
      assignment_order: assignment_policy.assignment_order,
      conversation_priority: assignment_policy.conversation_priority,
      fair_distribution_limit: assignment_policy.fair_distribution_limit,
      fair_distribution_window: assignment_policy.fair_distribution_window,
      inbox_ids: inboxes.map(&:id),
      inboxes: inboxes.map { |inbox| inbox_payload(inbox) },
      created_at: assignment_policy.created_at&.iso8601,
      updated_at: assignment_policy.updated_at&.iso8601
    }.compact
  end

  def account_inboxes_for(assignment_policy)
    assignment_policy.inboxes.select { |inbox| inbox.account_id == account.id }
  end

  def inbox_payload(inbox)
    {
      id: inbox.id,
      name: inbox.name,
      channel_type: inbox.channel_type
    }
  end
end
