class Crm::Deals::ListOrderService
  SORT_COLUMNS = {
    'amount' => 'crm_deals.amount_minor',
    'amountMinor' => 'crm_deals.amount_minor',
    'id' => 'crm_deals.id',
    'owner' => <<~SQL.squish,
      (SELECT LOWER(COALESCE(users.name, users.email))
       FROM users
       WHERE users.id = crm_deals.owner_id
       LIMIT 1)
    SQL
    'stage' => "LOWER(COALESCE(crm_stages.name, ''))",
    'title' => 'LOWER(crm_deals.title)',
    'updatedAt' => 'crm_deals.updated_at'
  }.freeze

  def initialize(scope:, page:, per_page:, sort_by:, sort_direction:)
    @scope = scope
    @page = page
    @per_page = per_page
    @sort_by = sort_by
    @sort_direction = sort_direction
  end

  def perform
    column = SORT_COLUMNS[sort_by]
    ordered_scope = column.present? ? sorted_scope(column) : scope.ordered
    ordered_scope.offset((page - 1) * per_page).limit(per_page)
  end

  private

  attr_reader :page, :per_page, :scope, :sort_by, :sort_direction

  def direction
    sort_direction.to_s.downcase == 'desc' ? 'DESC' : 'ASC'
  end

  def sorted_scope(column)
    relation = sort_by == 'stage' ? scope.left_joins(:stage) : scope
    relation.reorder(Arel.sql("#{column} #{direction} NULLS LAST, crm_deals.id #{direction}"))
  end
end
