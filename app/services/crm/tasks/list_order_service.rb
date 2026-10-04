class Crm::Tasks::ListOrderService
  DEFAULT_PER_PAGE = 100
  MAX_PER_PAGE = 500
  SORT_COLUMNS = {
    'activityType' => "LOWER(COALESCE(list_sort_task_types.name, crm_tasks.activity_type, ''))",
    'assignee' => "LOWER(COALESCE(users.name, users.email, ''))",
    'dueAt' => 'COALESCE(crm_tasks.due_at, crm_tasks.due_on::timestamp)',
    'id' => 'crm_tasks.id',
    'title' => 'LOWER(crm_tasks.title)'
  }.freeze

  def initialize(scope:, params:)
    @scope = scope
    @params = params
  end

  def perform
    column = SORT_COLUMNS[params[:sort_by]]
    ordered_scope = column.present? ? sorted_scope(column) : scope.ordered
    ordered_scope.offset((page - 1) * per_page).limit(per_page)
  end

  def page
    value = params[:page].to_i
    value.positive? ? value : 1
  end

  def per_page
    value = params[:per_page].to_i
    return DEFAULT_PER_PAGE unless value.positive?

    [value, MAX_PER_PAGE].min
  end

  private

  attr_reader :params, :scope

  def direction
    params[:sort_direction].to_s.downcase == 'desc' ? 'DESC' : 'ASC'
  end

  def sorted_scope(column)
    relation = case params[:sort_by]
               when 'activityType' then scope.joins(activity_type_catalog_join)
               when 'assignee' then scope.left_joins(:assignee)
               else scope
               end
    relation.reorder(Arel.sql("#{column} #{direction} NULLS LAST, crm_tasks.id #{direction}"))
  end

  def activity_type_catalog_join
    Arel.sql(<<~SQL.squish)
      LEFT OUTER JOIN crm_task_types AS list_sort_task_types
        ON list_sort_task_types.account_id = crm_tasks.account_id
        AND (
          list_sort_task_types.id = crm_tasks.task_type_id
          OR (
            crm_tasks.task_type_id IS NULL
            AND list_sort_task_types.code = crm_tasks.activity_type
          )
        )
    SQL
  end
end
