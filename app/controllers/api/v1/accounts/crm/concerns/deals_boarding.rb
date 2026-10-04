module Api::V1::Accounts::Crm::Concerns::DealsBoarding
  DEFAULT_PER_PAGE = 100
  MAX_PER_PAGE = 500

  BOARD_SORT_COLUMNS = {
    'amount' => 'COALESCE(crm_deals.amount_minor, 0)',
    'createdAt' => 'crm_deals.created_at',
    'expectedCloseOn' => 'crm_deals.expected_close_on',
    'position' => 'crm_deals.position',
    'title' => 'LOWER(crm_deals.title)',
    'updatedAt' => 'crm_deals.updated_at'
  }.freeze

  private

  def page_param
    value = params[:page].presence || 1
    value.to_i.clamp(1, 10_000)
  end

  def per_page_param
    value = params[:per_page].presence || params[:limit].presence || DEFAULT_PER_PAGE
    value.to_i.clamp(1, MAX_PER_PAGE)
  end

  def page_offset
    (page_param - 1) * per_page_param
  end

  def board_mode?
    parse_boolean(params[:board])
  end

  def board_page(scope)
    ranked_deals = scope.except(:preload).reorder(nil).select('crm_deals.*', Arel.sql(board_row_number_sql))

    ::Crm::Deal
      .with(ranked_deals: ranked_deals)
      .from('ranked_deals AS crm_deals')
      .where(board_row_number: (page_offset + 1)..(page_offset + per_page_param))
      .preload(*deal_preloads)
      .reorder(Arel.sql('crm_deals.stage_id ASC, crm_deals.board_row_number ASC'))
  end

  def board_row_number_sql
    <<~SQL.squish
      ROW_NUMBER() OVER (
        PARTITION BY crm_deals.stage_id
        ORDER BY #{board_order_sql}
      ) AS board_row_number
    SQL
  end

  def board_order_sql
    sort_column = BOARD_SORT_COLUMNS.fetch(params[:board_sort].to_s, BOARD_SORT_COLUMNS.fetch('position'))
    return "#{sort_column} ASC NULLS LAST, crm_deals.id ASC" if sort_column == BOARD_SORT_COLUMNS.fetch('position')

    descending_stage_ids = board_sort_directions.filter_map do |stage_id, direction|
      numeric_stage_id = stage_id.to_i
      numeric_stage_id if numeric_stage_id.positive? && direction == 'desc'
    end
    return "#{sort_column} ASC NULLS LAST, crm_deals.id ASC" if descending_stage_ids.empty?

    id_list = descending_stage_ids.join(', ')
    <<~SQL.squish
      CASE WHEN crm_deals.stage_id IN (#{id_list}) THEN #{sort_column} END DESC NULLS LAST,
      CASE WHEN crm_deals.stage_id NOT IN (#{id_list}) THEN #{sort_column} END ASC NULLS LAST,
      crm_deals.id ASC
    SQL
  end

  def board_sort_directions
    raw_directions = params[:board_sort_directions]
    return {} unless raw_directions.respond_to?(:to_unsafe_h)

    raw_directions.to_unsafe_h.transform_values(&:to_s)
  end

  def pagination_meta(scope, records)
    stage_counts = scope.reorder(nil).group(:stage_id).count.transform_keys(&:to_s)
    total_count = stage_counts.values.sum
    paginated_count = board_mode? ? stage_counts.values.max.to_i : total_count
    total_pages = (paginated_count.to_f / per_page_param).ceil

    {
      count: records.size,
      has_more: page_param < total_pages,
      page: page_param,
      per_page: per_page_param,
      stage_counts: stage_counts,
      total_count: total_count,
      total_pages: total_pages
    }
  end
end
