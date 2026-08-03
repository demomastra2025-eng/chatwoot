class Captain::Tools::Copilot::GetArticleService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_article'
  end

  description 'Get details of an article including its content and metadata'
  param :article_id, type: :number, desc: 'The ID of the article to retrieve', required: true

  def execute(article_id:)
    article = account.articles.includes(:portal, :author).find_by(id: article_id)
    return tool_failure('Article not found') if article.nil?

    formatted_payload(article: article_payload(article))
  end

  def active?
    user_has_permission('knowledge_base_manage')
  end

  private

  def article_payload(article)
    {
      id: article.id,
      title: article.title,
      description: article.description,
      content: article.content,
      slug: article.slug,
      locale: article.locale,
      status: article.status,
      portal_id: article.portal_id,
      portal_name: article.portal&.name,
      author_id: article.author_id,
      author_name: article.author&.name,
      category_id: article.category_id,
      views: article.views,
      meta: article.meta,
      created_at: article.created_at&.iso8601,
      updated_at: article.updated_at&.iso8601
    }
  end
end
