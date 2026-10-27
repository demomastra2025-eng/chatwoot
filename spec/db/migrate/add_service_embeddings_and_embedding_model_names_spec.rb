require 'rails_helper'
require Rails.root.join('db/migrate/20261027120000_add_service_embeddings_and_embedding_model_names')

# The columns of the service vectors and the model names are added in short, retried steps, and the vectors that exist at that moment get
# the name of the model that made them (the setting in force, or the built-in default of the time), so that the searches keep working on
# them until the full re-embedding switches the model. The columns exist in the test database already: the migration adds them only when
# they are missing, so it can run again.
RSpec.describe AddServiceEmbeddingsAndEmbeddingModelNames do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:vector) { Array.new(Captain::KnowledgeSettings::VECTOR_DIMENSIONS, 0.1) }
  let!(:faq) { create(:captain_assistant_response, account: account, assistant: assistant) }
  let!(:faq_without_vector) { create(:captain_assistant_response, account: account, assistant: assistant) }
  let!(:already_marked) { create(:captain_assistant_response, account: account, assistant: assistant) }
  let!(:article_embedding) do
    portal = create(:portal, account: account)
    article = create(:article, account: account, portal: portal, category: nil)
    article.article_embeddings.destroy_all
    ArticleEmbedding.create!(article: article, term: 'Как записаться')
  end
  let!(:chunk) do
    document = create(:captain_document, account: account, assistant: assistant)
    create(:captain_document_chunk, account: account, assistant: assistant, document: document)
  end

  before do
    [faq, already_marked, article_embedding, chunk].each do |record|
      record.update_columns(embedding: vector, embedding_model: nil) # rubocop:disable Rails/SkipsModelValidations
    end
    already_marked.update_columns(embedding_model: 'google/gemini-embedding-001') # rubocop:disable Rails/SkipsModelValidations
    faq_without_vector.update_columns(embedding: nil, embedding_model: nil) # rubocop:disable Rails/SkipsModelValidations
  end

  def migrate_up
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
  end

  it 'marks the existing vectors with the model named by the setting, and leaves the marked ones and the rows without a vector alone' do
    upsert_installation_config('CAPTAIN_EMBEDDING_MODEL', 'text-embedding-3-large')

    migrate_up

    expect(faq.reload.embedding_model).to eq('text-embedding-3-large')
    expect(article_embedding.reload.embedding_model).to eq('text-embedding-3-large')
    expect(chunk.reload.embedding_model).to eq('text-embedding-3-large')
    expect(already_marked.reload.embedding_model).to eq('google/gemini-embedding-001')
    expect(faq_without_vector.reload.embedding_model).to be_nil
  end

  it 'uses the built-in default of the time, text-embedding-3-small, when the setting was never set' do
    InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.destroy!

    migrate_up

    expect(faq.reload.embedding_model).to eq('text-embedding-3-small')
  end

  it 'can run again: nothing changes the second time' do
    upsert_installation_config('CAPTAIN_EMBEDDING_MODEL', 'text-embedding-3-large')
    migrate_up
    upsert_installation_config('CAPTAIN_EMBEDDING_MODEL', 'google/gemini-embedding-001')

    migrate_up

    expect(faq.reload.embedding_model).to eq('text-embedding-3-large')
  end

  it 'bounds every table change by a lock timeout and retries it a few times' do
    statements = []
    allow(ActiveRecord::Base.connection).to receive(:execute).and_wrap_original do |original, sql, *args|
      statements << sql
      original.call(sql, *args)
    end

    migrate_up

    expect(statements.grep(/SET LOCAL lock_timeout = '5s'/).size).to be >= 5
    expect(described_class::LOCK_ATTEMPTS).to eq(5)
  end
end
