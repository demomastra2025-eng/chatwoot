require 'rails_helper'

# The full re-embedding with one model: a dry run that touches nothing, a backup of the old vectors, all-or-nothing storage together with
# the CAPTAIN_EMBEDDING_MODEL setting, and a restore. The embedding model is a fake; the database is real. All data is synthetic.
RSpec.describe Captain::Llm::EmbeddingReindexService do
  let(:target) { 'google/gemini-embedding-001' }
  let(:legacy) { 'text-embedding-3-large' }
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:backup_dir) { Rails.root.join('tmp', "embedding-backup-spec-#{SecureRandom.hex(4)}").to_s }
  let(:out) { StringIO.new }
  let(:embedder) { instance_double(Captain::Llm::EmbeddingService) }
  let(:calls) { [] }
  let!(:faq) { create(:captain_assistant_response, account: account, assistant: assistant, question: 'Где вы находитесь?', answer: 'Абая 1') }
  let!(:cache_entry) do
    Captain::KnowledgeAnswerCacheEntry.create!(account: account, assistant: assistant, query: 'где вы находитесь', query_sha256: 'abc',
                                               source_fingerprint: 'fp', payload: { 'a' => 1 }, embedding: old_vector)
  end
  let!(:chunk) do
    document = create(:captain_document, account: account, assistant: assistant)
    create(:captain_document_chunk, account: account, assistant: assistant, document: document, content: 'Текст фрагмента')
  end
  let!(:service) { create(:scheduling_service, account: account, name: 'Консультация терапевта', category: 'Консультации') }
  let!(:article_embedding) do
    portal = create(:portal, account: account)
    article = create(:article, account: account, portal: portal, category: nil)
    article.article_embeddings.destroy_all
    ArticleEmbedding.create!(article: article, term: 'Как записаться', embedding: old_vector)
  end

  before do
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'test-key')
    upsert_installation_config('CAPTAIN_EMBEDDING_MODEL', legacy)
    [faq, chunk].each { |record| record.update_columns(embedding: old_vector, embedding_model: legacy) } # rubocop:disable Rails/SkipsModelValidations
    [cache_entry, article_embedding].each { |record| record.update_columns(embedding_model: legacy) } # rubocop:disable Rails/SkipsModelValidations
    allow(embedder).to receive(:get_embeddings) do |texts, **options|
      calls << { texts: texts, **options }
      texts.map { new_vector }
    end
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(embedder)
  end

  def new_vector
    unit_vector(7)
  end

  def old_vector
    unit_vector(3)
  end

  def vector_text(table, id)
    ActiveRecord::Base.connection.select_value("SELECT embedding::text FROM #{table} WHERE id = #{id}")
  end

  def service_for(**)
    described_class.new(model: target, backup_dir: backup_dir, out: out, **)
  end

  after { FileUtils.rm_rf(backup_dir) }

  describe '#preview' do
    it 'counts what apply would embed and calls no model and writes nothing', :aggregate_failures do
      old_faq_vector = vector_text('captain_assistant_responses', faq.id)

      plan = service_for.preview

      expect(plan).to include(model: target, current_model: legacy, switches_model: true, key_configured: true)
      expect(plan[:sources].transform_values { |item| item[:rows] }).to eq('faq' => 1, 'cache' => 1, 'articles' => 1, 'chunks' => 1, 'services' => 1)
      expect(plan[:sources]['faq']).to include(chars: 'Где вы находитесь?: Абая 1'.length, requests: 1, with_vector_now: 1)
      expect(plan).to include(rows: 5, requests: 5)
      expect(plan[:estimated_tokens]).to eq((plan[:chars] * described_class::TOKENS_PER_CHAR).round)
      expect(Captain::Llm::EmbeddingService).not_to have_received(:new)
      expect(InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL').value).to eq(legacy)
      expect(vector_text('captain_assistant_responses', faq.id)).to eq(old_faq_vector)
      expect(faq.reload.embedding_model).to eq(legacy)
    end

    it 'says that the key is missing' do
      InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY').destroy!

      expect(service_for.preview[:key_configured]).to be(false)
    end
  end

  describe '#status' do
    it 'shows which model made the vectors of each table and the vectors of a wrong size' do
      status = service_for.status

      expect(status['faq'][:vectors_by_model]).to eq(legacy => 1)
      expect(status['services']).to include(rows: 1, vectors_by_model: {}, wrong_size: 0)
      expect(status.values.sum { |item| item[:wrong_size] }).to eq(0)
    end

    it 'counts a vector without a model name as unknown' do
      faq.update_columns(embedding_model: nil) # rubocop:disable Rails/SkipsModelValidations

      expect(service_for.status['faq'][:vectors_by_model]).to eq('unknown' => 1)
    end
  end

  describe '#apply!' do
    it 'backs up the old vectors, stores the new ones with the model, checksum and time, and switches the setting', :aggregate_failures do
      old_faq_vector = vector_text('captain_assistant_responses', faq.id)

      manifest = service_for.apply!

      expect(faq.reload).to have_attributes(embedding_model: target,
                                            embedding_checksum: Captain::Llm::EmbeddingService.checksum('Где вы находитесь?: Абая 1'))
      expect(cache_entry.reload.embedding_model).to eq(target)
      expect(chunk.reload.embedding_model).to eq(target)
      expect(article_embedding.reload.embedding_model).to eq(target)
      expect(service.reload).to have_attributes(embedding_model: target, embedding_checksum: Scheduling::ServiceIndex.checksum(service))
      expect(service.embedded_at).to be_present
      expect(vector_text('captain_assistant_responses', faq.id)).not_to eq(old_faq_vector)
      expect(InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL').value).to eq(target)
      expect(manifest['status'].values.map { |item| item[:vectors_by_model] }).to all(eq(target => 1))

      manifest_file = JSON.parse(File.read(File.join(backup_dir, 'manifest.json')))
      expect(manifest_file['previous_setting']).to eq('exists' => true, 'value' => legacy)
      expect(manifest_file['files'].transform_values { |item| item['rows'] })
        .to eq('faq' => 1, 'cache' => 1, 'articles' => 1, 'chunks' => 1, 'services' => 1)
      expect(Zlib::GzipReader.open(File.join(backup_dir, 'faq.jsonl.gz'), &:read)).to include(old_faq_vector)
      expect(File.stat(File.join(backup_dir, 'faq.jsonl.gz')).mode & 0o777).to eq(0o600)
      expect(File.stat(backup_dir).mode & 0o777).to eq(0o700)
    end

    it 'embeds the cache queries as queries and everything else as documents, in batches per account' do
      service_for.apply!

      by_type = calls.group_by { |call| call[:input_type] }
      expect(by_type.keys).to contain_exactly(Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE,
                                              Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
      expect(by_type[Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE].flat_map { |call| call[:texts] }).to eq(['где вы находитесь'])
      expect(calls.pluck(:model).uniq).to eq([target])
      expect(calls.flat_map { |call| call[:texts] })
        .to include('Где вы находитесь?: Абая 1', 'Консультация терапевта | Консультации', 'Как записаться')
    end

    it 'stores nothing, changes no setting and leaves the old vectors when the model fails' do
      allow(embedder).to receive(:get_embeddings).and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'HTTP 502')
      old_faq_vector = vector_text('captain_assistant_responses', faq.id)

      expect { service_for.apply! }.to raise_error(Captain::Llm::EmbeddingService::EmbeddingsError)

      expect(vector_text('captain_assistant_responses', faq.id)).to eq(old_faq_vector)
      expect(faq.reload.embedding_model).to eq(legacy)
      expect(service.reload.embedded_at).to be_nil
      expect(InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL').value).to eq(legacy)
    end

    it 'stops before the backup when the model answers with the wrong number of numbers' do
      allow(embedder).to receive(:get_embeddings).and_return([Array.new(3072, 0.1)])

      expect { service_for.apply! }.to raise_error(described_class::Error, /answered 3072 numbers, expected 1536/)
      expect(File.exist?(backup_dir)).to be(false)
    end

    it 'stops before anything when there is no OpenRouter key or no backup directory' do
      InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY').destroy!
      expect { service_for.apply! }.to raise_error(described_class::Error, /not configured/)

      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'test-key')
      expect { described_class.new(model: target).apply! }.to raise_error(described_class::Error, /BACKUP_DIR/)
    end

    it 'rolls the whole store back, setting included, when one write fails' do
      allow(InstallationConfig).to receive(:find_or_initialize_by).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect { service_for.apply! }.to raise_error(ActiveRecord::StatementInvalid)

      expect(faq.reload.embedding_model).to eq(legacy)
      expect(service.reload.embedding_model).to be_nil
    end
  end

  describe '#restore!' do
    it 'puts back the old vectors, models and setting exactly, and clears the vectors of rows made after the backup' do
      old = { faq: vector_text('captain_assistant_responses', faq.id), cache: vector_text('captain_knowledge_answer_cache_entries', cache_entry.id) }
      service_for.apply!
      newer = create(:scheduling_service, account: account, name: 'Новая услуга')
      Scheduling::ServiceIndex.store!(newer, new_vector, target)

      service_for.restore!

      expect(vector_text('captain_assistant_responses', faq.id)).to eq(old[:faq])
      expect(vector_text('captain_knowledge_answer_cache_entries', cache_entry.id)).to eq(old[:cache])
      expect(faq.reload).to have_attributes(embedding_model: legacy, embedding_checksum: nil)
      expect(service.reload).to have_attributes(embedding_model: nil, embedding_checksum: nil, embedded_at: nil)
      expect(newer.reload).to have_attributes(embedding_model: nil, embedded_at: nil)
      expect(InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL').value).to eq(legacy)
    end

    it 'removes the setting again when there was none before' do
      InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL').destroy!
      service_for.apply!

      service_for.restore!

      expect(InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')).to be_nil
    end

    it 'refuses a backup whose file was changed' do
      service_for.apply!
      File.write(File.join(backup_dir, 'faq.jsonl.gz'), 'tampered')

      expect { service_for.restore! }.to raise_error(Captain::Llm::EmbeddingBackup::Error, /does not match its checksum/)
      expect(faq.reload.embedding_model).to eq(target)
    end
  end
end
