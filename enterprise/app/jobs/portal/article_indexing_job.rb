class Portal::ArticleIndexingJob < ApplicationJob
  queue_as :low
  discard_on ActiveJob::DeserializationError

  def perform(article)
    article.generate_and_save_article_seach_terms
  end
end
