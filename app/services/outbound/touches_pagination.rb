class Outbound::TouchesPagination
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100

  def initialize(scope:, page:, per_page:)
    @scope = scope
    @paginated = page.present? || per_page.present?
    @page_number = page.to_i.clamp(1, 10_000)
    @per_page = (per_page.presence || DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
  end

  def records
    return scope unless paginated?

    @records ||= scope.reorder(updated_at: :desc, created_at: :desc, id: :desc).page(page_number).per(per_page)
  end

  def metadata
    return { count: scope.size } unless paginated?

    {
      count: records.total_count,
      current_page: records.current_page,
      per_page: records.limit_value,
      total_pages: records.total_pages
    }
  end

  private

  attr_reader :scope, :page_number, :per_page

  def paginated?
    @paginated
  end
end
