module Enterprise::Concerns::Article
  extend ActiveSupport::Concern

  included do
    after_save :add_article_embedding, if: -> { saved_change_to_title? || saved_change_to_description? || saved_change_to_content? }

    def self.add_article_embedding_association
      has_many :article_embeddings, dependent: :destroy_async
    end

    add_article_embedding_association

    def self.vector_search(params)
      embedding = Captain::Llm::EmbeddingService.new(account_id: params[:account_id]).get_embedding(params['query'])
      records = joins(
        :category
      ).search_by_category_slug(
        params[:category_slug]
      ).search_by_category_locale(params[:locale]).search_by_author(params[:author_id]).search_by_status(params[:status])
      filtered_article_ids = records.pluck(:id)

      # Fetch nearest neighbors and their distances, then filter directly

      # experimenting with filtering results based on result threshold
      # distance_threshold = 0.2
      # if using add the filter block to the below query
      # .filter { |ae| ae.neighbor_distance <= distance_threshold }

      article_ids = ArticleEmbedding.where(article_id: filtered_article_ids)
                                    .nearest_neighbors(:embedding, embedding, distance: 'cosine')
                                    .limit(5)
                                    .pluck(:article_id)

      # Fetch the articles by the IDs obtained from the nearest neighbors search
      where(id: article_ids)
    end
  end

  def add_article_embedding
    return unless account.feature_enabled?('help_center_embedding_search')

    Portal::ArticleIndexingJob.perform_later(self)
  end

  def generate_and_save_article_seach_terms
    preserve_existing_embeddings = article_embeddings.exists?
    terms = Captain::Llm::ArticleSearchTermsService.new(self).generate
    return if terms.blank? && preserve_existing_embeddings

    terms = fallback_article_search_terms if terms.blank?
    return if terms.blank?

    article_embeddings.destroy_all
    terms.each { |term| article_embeddings.create!(term: term) }
  end

  private

  def fallback_article_search_terms
    content_text = Loofah.fragment(content.to_s).text.squish
    content_excerpt = content_text.split.take(40).join(' ').presence

    [
      title.to_s.squish.presence,
      description.to_s.squish.presence,
      content_excerpt
    ].compact.uniq
  end
end
