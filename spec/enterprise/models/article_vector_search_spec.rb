require 'rails_helper'

# The help center search by meaning compares the question only with the term vectors that the model embedding the question made:
# vectors of two models cannot be compared. All data is synthetic.
RSpec.describe Article, '.vector_search' do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:category) { create(:category, portal: portal, account: account) }
  let(:author) { create(:user, account: account) }
  let(:vector) { Array.new(Captain::KnowledgeSettings::VECTOR_DIMENSIONS, 0.0).tap { |values| values[0] = 1.0 } }
  let(:embedder) { instance_double(Captain::Llm::EmbeddingService, embedding_model: 'google/gemini-embedding-001', get_embedding: vector) }

  def article_with_term(title, model)
    article = create(:article, account: account, portal: portal, category: category, author: author, title: title, status: :published)
    article.article_embeddings.destroy_all
    ArticleEmbedding.create!(article: article, term: title).tap do |term|
      term.update_columns(embedding: vector, embedding_model: model) # rubocop:disable Rails/SkipsModelValidations
    end
    article
  end

  before { allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedder) }

  it 'finds the articles whose term was embedded by the same model, and not the others' do
    same = article_with_term('How to book', 'google/gemini-embedding-001')
    article_with_term('How to pay', 'text-embedding-3-large')
    article_with_term('How to cancel', nil)

    found = described_class.vector_search(ActiveSupport::HashWithIndifferentAccess.new(query: 'book', account_id: account.id))

    expect(found.pluck(:id)).to eq([same.id])
    expect(embedder).to have_received(:get_embedding).with('book', input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
  end
end
