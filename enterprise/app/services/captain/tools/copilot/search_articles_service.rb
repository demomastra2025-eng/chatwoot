class Captain::Tools::Copilot::SearchArticlesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_articles'
  end

  description 'Search knowledge base articles by query, category, or status. ' \
              'Never guess category_id; omit it unless the user provided a verified category ID.'
  param :query, type: :string, desc: 'Search articles by title or content (partial match)', required: false
  param :category_id, type: :number,
                      desc: 'Optional verified category ID. Never guess or default it; omit it for general title/content search.',
                      required: false
  param :status, type: :string, desc: 'Filter articles by status: draft, published, archived', required: false
  param :limit, type: :number, desc: 'Maximum number of articles to return', required: false

  def execute(query: nil, category_id: nil, status: nil, limit: nil)
    category_id = optional_positive_id(category_id)
    validate_category!(category_id)
    articles = fetch_articles(query: query, category_id: category_id, status: status)
    total_count = articles.count
    records = articles.limit(parse_limit(limit)).map { |article| article_payload(article) }

    formatted_payload(
      filters: {
        query: query,
        category_id: category_id,
        status: status
      }.compact,
      total_count: total_count,
      articles: records
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    user_has_permission('knowledge_base_manage')
  end

  private

  def validate_category!(category_id)
    return if category_id.blank?
    return if Category.where(account_id: account.id).exists?(id: category_id)

    raise ArgumentError,
          "Unknown category_id #{category_id} for the current account. Omit category_id unless the user provided a verified category ID."
  end

  def fetch_articles(query:, category_id:, status:)
    scope = account.articles.includes(:portal, :author).order(updated_at: :desc, id: :desc)
    scope = scope.where('title ILIKE :query OR content ILIKE :query', query: "%#{query}%") if query.present?
    scope = scope.where(category_id: category_id) if category_id.present?
    scope = scope.where(status: status) if status.present?
    scope
  end

  def article_payload(article)
    {
      id: article.id,
      title: article.title,
      description: article.description,
      content: article.content,
      slug: article.slug,
      locale: article.locale,
      status: article.status,
      category_id: article.category_id,
      portal_id: article.portal_id,
      portal_name: article.portal&.name,
      author_id: article.author_id,
      author_name: article.author&.name,
      created_at: article.created_at&.iso8601,
      updated_at: article.updated_at&.iso8601
    }
  end
end
