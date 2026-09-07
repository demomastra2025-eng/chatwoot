class Crm::Tasks::FilterService
  EXACT_FIELDS = %i[
    status_id activity_type task_type_id task_outcome_id outcome assignee_id team_id priority deal_id
  ].freeze

  def initialize(account:, scope:, params:, custom_attribute_filters:)
    @account = account
    @scope = scope
    @params = params
    @custom_attribute_filters = custom_attribute_filters
  end

  def perform
    filtered_scope = EXACT_FIELDS.reduce(base_scope) { |result, field| filter_by_exact(result, field) }
    filtered_scope = filter_by_due_range(filtered_scope)
    filtered_scope = filter_by_query(filtered_scope)
    apply_custom_attribute_filters(filtered_scope)
  end

  private

  attr_reader :account, :params, :custom_attribute_filters

  def base_scope
    archived? ? @scope.archived : @scope.kept
  end

  def archived?
    ActiveModel::Type::Boolean.new.cast(params[:archived])
  end

  def filter_by_exact(scope, field_name)
    return scope if params[field_name].blank?

    scope.where(field_name => params[field_name])
  end

  def filter_by_due_range(scope)
    from = parse_datetime(:due_from)
    to = parse_datetime(:due_to)
    return scope if from.blank? && to.blank?

    scope.where(
      due_range_clause(from: from, to: to),
      from: from,
      to: to,
      from_date: workspace_date(from),
      to_date: workspace_date(to)
    )
  end

  def parse_datetime(field_name)
    value = params[field_name]
    return if value.blank?

    Time.zone.parse(value.to_s) || raise(ArgumentError, "#{field_name} must be a valid datetime")
  end

  def workspace_date(value)
    value&.in_time_zone(account.workspace_working_hours_timezone)&.to_date
  end

  def due_range_clause(from:, to:)
    return bounded_due_range_clause if from.present? && to.present?
    return 'crm_tasks.due_at >= :from OR crm_tasks.due_on >= :from_date' if from.present?

    'crm_tasks.due_at < :to OR crm_tasks.due_on < :to_date'
  end

  def bounded_due_range_clause
    <<~SQL.squish
      (crm_tasks.due_at >= :from AND crm_tasks.due_at < :to) OR
      (crm_tasks.due_on >= :from_date AND crm_tasks.due_on < :to_date)
    SQL
  end

  def filter_by_query(scope)
    return scope if params[:q].blank?

    query = "%#{params[:q].to_s.strip}%"
    scope.where('crm_tasks.title ILIKE :query OR crm_tasks.external_ref ILIKE :query', query: query)
  end

  def apply_custom_attribute_filters(scope)
    ::Crm::CustomFieldFilterSet.new(
      account: account,
      entity_kind: 'task',
      raw_filters: custom_attribute_filters
    ).apply(scope)
  end
end
