require 'rails_helper'

# The vector index of the service catalog: what a service is embedded as, which services are stale, the batch refresh, and the nearest
# services to a query vector. The embedding model is the fake of ServiceEmbeddingHelpers. All data is synthetic.
RSpec.describe Scheduling::ServiceIndex do
  let(:account) { create(:account) }
  let(:service) { create(:scheduling_service, account: account, name: 'УЗИ  щитовидной железы', category: 'УЗИ') }

  describe '.text' do
    it 'is "name | aliases | category", squished, with the empty parts left out' do
      expect(described_class.text(service)).to eq('УЗИ щитовидной железы | УЗИ')

      service.update!(custom_attributes: { 'aliases' => ["УЗИ щитовидки\n  ультразвук щитовидной", ' ', 'ТТГ'] })
      expect(described_class.text(service)).to eq('УЗИ щитовидной железы | УЗИ щитовидки; ультразвук щитовидной; ТТГ | УЗИ')

      service.update!(category: nil, custom_attributes: { 'aliases' => 'одна строка' })
      expect(described_class.text(service)).to eq('УЗИ щитовидной железы | одна строка')
    end

    it 'does not use the description, the direction, the price or the activity: the experiment gave no gain for them' do
      service.update!(description: 'Подробный текст', direction: 'Эндокринология', base_price: 1, active: false)

      expect(described_class.text(service)).to eq('УЗИ щитовидной железы | УЗИ')
    end
  end

  describe '.checksum' do
    it 'changes with the embedded text only' do
      before = described_class.checksum(service)

      service.update!(description: 'Другой текст', base_price: 5)
      expect(described_class.checksum(service)).to eq(before)

      service.update!(name: 'УЗИ щитовидной железы и шеи')
      expect(described_class.checksum(service)).not_to eq(before)
    end
  end

  describe '.stale_services' do
    let(:model) { ServiceEmbeddingHelpers::FAKE_MODEL }

    it 'lists a service without a vector, with a vector of another model, and with a vector of another text, and no other' do
      current = create(:scheduling_service, account: account, name: 'Текущая')
      other_model = create(:scheduling_service, account: account, name: 'Другая модель')
      changed = create(:scheduling_service, account: account, name: 'Изменённая')
      index_service(current, unit_vector(0))
      index_service(other_model, unit_vector(1), model: 'openai/text-embedding-3-large')
      index_service(changed, unit_vector(2))
      changed.update_columns(name: 'Изменённая услуга') # rubocop:disable Rails/SkipsModelValidations
      service

      expect(described_class.stale_services(account.id, model).map(&:id)).to contain_exactly(other_model.id, changed.id, service.id)
    end

    it 'does not read the services of another account' do
      create(:scheduling_service, account: create(:account))
      service

      expect(described_class.stale_services(account.id, ServiceEmbeddingHelpers::FAKE_MODEL).map(&:id)).to eq([service.id])
    end
  end

  describe '.refresh!' do
    let!(:embedder) { stub_embedder(account, 'щитовидной' => unit_vector(0), 'Другая' => unit_vector(1)) }

    it 'embeds the stale services as documents in one request and stores each vector with its model, checksum and time' do
      other = create(:scheduling_service, account: account, name: 'Другая услуга')
      service

      expect(described_class.refresh!(account.id)).to eq(2)

      expect(embedder).to have_received(:get_embeddings).once do |texts, input_type:|
        expect(texts).to contain_exactly('УЗИ щитовидной железы | УЗИ', 'Другая услуга')
        expect(input_type).to eq(Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE)
      end
      expect(service.reload).to have_attributes(embedding_model: ServiceEmbeddingHelpers::FAKE_MODEL,
                                                embedding_checksum: described_class.checksum(service))
      expect(service.embedded_at).to be_within(1.minute).of(Time.current)
      expect(other.reload.embedded_at).to be_present
    end

    it 'indexes nothing for a model without a calibrated threshold: the search could not use the vectors' do
      other = instance_double(Captain::Llm::EmbeddingService, embedding_model: 'openai/text-embedding-3-large')
      allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(other)
      service

      expect(described_class.refresh!(account.id)).to eq(0)
      expect(service.reload.embedded_at).to be_nil
    end

    it 'skips the services whose checksum and model are current: a second run asks the model nothing' do
      service
      described_class.refresh!(account.id)

      expect(described_class.refresh!(account.id)).to eq(0)
      expect(embedder).to have_received(:get_embeddings).once
    end

    it 'embeds a changed service again, and only that one' do
      service
      other = create(:scheduling_service, account: account, name: 'Другая услуга')
      described_class.refresh!(account.id)
      service.update!(name: 'УЗИ щитовидной железы и шеи')

      expect(described_class.refresh!(account.id)).to eq(1)
      expect(embedder).to have_received(:get_embeddings).with(['УЗИ щитовидной железы и шеи | УЗИ'], anything)
      expect(other.reload.embedding_checksum).to eq(described_class.checksum(other))
    end

    it 'sends a long catalog in batches of 64 services' do
      allow(embedder).to receive(:get_embeddings) { |texts, **| texts.map { unit_vector(0) } }
      Array.new(70) { |index| create(:scheduling_service, account: account, name: "Услуга номер #{index}") }

      expect(described_class.refresh!(account.id)).to eq(70)
      expect(embedder).to have_received(:get_embeddings).twice
    end

    it 'stores a vector of 1536 numbers, normalized to unit length like the vectors of the models, that the database can search' do
      allow(embedder).to receive(:get_embeddings) { |texts, **| texts.map { unit_vector(0).map { |value| value * 3.0 } } }
      service
      described_class.refresh!(account.id)

      row = Scheduling::Service.connection.select_one(
        "SELECT vector_dims(embedding) AS dims, -(embedding <#> embedding) AS squared_norm FROM scheduling_services WHERE id = #{service.id}"
      )
      expect(row['dims']).to eq(Captain::KnowledgeSettings::VECTOR_DIMENSIONS)
      expect(row['squared_norm'].to_f).to be_within(0.0001).of(1.0)
    end
  end

  describe '.readiness' do
    it 'counts the services of the scope and those whose vector was made by the model in force' do
      ready = create(:scheduling_service, account: account)
      create(:scheduling_service, account: account)
      create(:scheduling_service, account: account, active: false)
      index_service(ready, unit_vector(0))
      scope = account.scheduling_services.active

      expect(described_class.readiness(scope, ServiceEmbeddingHelpers::FAKE_MODEL)).to eq(total: 2, searchable: 1)
      expect(described_class.readiness(scope, 'another/model')).to eq(total: 2, searchable: 0)
      expect(described_class.readiness(account.scheduling_services, ServiceEmbeddingHelpers::FAKE_MODEL)).to eq(total: 3, searchable: 1)
    end

    it 'does not count a service whose vector was taken out of the search' do
      ready = create(:scheduling_service, account: account)
      index_service(ready, unit_vector(0))
      described_class.invalidate!(ready.id)

      expect(described_class.readiness(account.scheduling_services, ServiceEmbeddingHelpers::FAKE_MODEL)).to eq(total: 1, searchable: 0)
    end
  end

  describe '.min_score and .calibrated?' do
    it 'is the threshold of config/llm.yml for the model, and nothing for a model that was not calibrated' do
      expect(described_class.min_score('google/gemini-embedding-001')).to eq(0.66)
      expect(described_class).to be_calibrated('google/gemini-embedding-001')
      expect(described_class.min_score('openai/text-embedding-3-large')).to be_nil
      expect(described_class).not_to be_calibrated('openai/text-embedding-3-large')
      expect(described_class.min_score(nil)).to be_nil
    end
  end

  describe '.store!' do
    it 'stores nothing, and says so, when the service was renamed after its text was embedded' do
      stale_text = described_class.text(service)
      service.update_columns(name: 'Совсем другое название') # rubocop:disable Rails/SkipsModelValidations

      expect(described_class.store!(service, unit_vector(0), ServiceEmbeddingHelpers::FAKE_MODEL, text: stale_text)).to be(false)
      expect(service.reload.embedded_at).to be_nil

      expect(described_class.store!(service, unit_vector(0), ServiceEmbeddingHelpers::FAKE_MODEL)).to be(true)
      expect(service.reload.embedded_at).to be_present
    end
  end

  describe '.invalidate!' do
    it 'takes the vector out of the search and makes the service stale until it is embedded again' do
      index_service(service, unit_vector(0))

      described_class.invalidate!(service.id)

      expect(service.reload.embedded_at).to be_nil
      expect(described_class.stale_services(account.id, ServiceEmbeddingHelpers::FAKE_MODEL).map(&:id)).to eq([service.id])
    end
  end

  describe '.nearest' do
    let(:model) { ServiceEmbeddingHelpers::FAKE_MODEL }
    let!(:near) { create(:scheduling_service, account: account, name: 'Близкая').tap { |record| index_service(record, vector_at(0, 0.9)) } }
    let!(:far) { create(:scheduling_service, account: account, name: 'Дальняя').tap { |record| index_service(record, vector_at(0, 0.4)) } }
    let!(:unrelated) { create(:scheduling_service, account: account, name: 'Чужая').tap { |record| index_service(record, unit_vector(5)) } }

    it 'returns the services best first with their cosine similarity, one list per query vector' do
      lists = described_class.nearest(account.scheduling_services, [unit_vector(0), unit_vector(5)], model: model, limit: 10)

      expect(lists.map { |hits| hits.map { |hit| hit.service.id } }).to eq([[near.id, far.id, unrelated.id], [unrelated.id, near.id, far.id]])
      expect(lists.first.map { |hit| hit.score.round(2) }).to eq([0.9, 0.4, 0.0])
      expect(lists.second.first.score).to be_within(0.0001).of(1.0)
    end

    it 'cuts each list at the limit and leaves the vector column out of the services it returns' do
      hit = described_class.nearest(account.scheduling_services, [unit_vector(0)], model: model, limit: 1).first.first

      expect(hit.service).to have_attributes(id: near.id, name: 'Близкая')
      expect(hit.service.attributes.keys).not_to include('embedding')
    end

    it 'uses the scope it is given and ignores the vectors of another model and the services that have none' do
      create(:scheduling_service, account: account, name: 'Без вектора')
      index_service(far, unit_vector(0), model: 'openai/text-embedding-3-large')

      lists = described_class.nearest(account.scheduling_services.where.not(id: unrelated.id), [unit_vector(0)], model: model, limit: 10)

      expect(lists.first.map { |hit| hit.service.id }).to eq([near.id])
    end

    it 'finds nothing when no vector has the model' do
      expect(described_class.nearest(account.scheduling_services, [unit_vector(0)], model: 'another/model', limit: 10)).to eq([[]])
    end
  end
end
