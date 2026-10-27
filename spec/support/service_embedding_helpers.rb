# frozen_string_literal: true

# A fake embedding model for the specs of the service search. Every concept is one axis of the 1536-number space, so the cosine
# similarity of two texts is known exactly: the same concept 1.0, unrelated concepts 0.0, anything between with vector_at.
module ServiceEmbeddingHelpers
  FAKE_MODEL = 'google/gemini-embedding-001'
  DIMENSIONS = Captain::KnowledgeSettings::VECTOR_DIMENSIONS

  # The unit vector of one concept.
  def unit_vector(axis)
    Array.new(DIMENSIONS, 0.0).tap { |vector| vector[axis] = 1.0 }
  end

  # A unit vector whose cosine similarity to unit_vector(axis) is `similarity` (the rest points to the neighbouring axis).
  def vector_at(axis, similarity)
    unit_vector(axis).tap do |vector|
      vector[axis] = similarity
      vector[axis + 1] = Math.sqrt(1.0 - (similarity**2))
    end
  end

  # The embedder of an account: a text is embedded as the vector of the first key of `mapping` (text => vector) that it contains; any other
  # text raises.
  # Returns the double, so a spec can expect how often and with which texts it was asked.
  def stub_embedder(account, mapping = {}, model: FAKE_MODEL, **inline)
    mapping = mapping.merge(inline)
    embedder = instance_double(Captain::Llm::EmbeddingService, embedding_model: model)
    allow(embedder).to receive(:get_embeddings) do |texts, **|
      texts.map do |text|
        _key, vector = mapping.find { |key, _| text.include?(key) }
        vector || raise("the fake embedder knows no vector for #{text.inspect}")
      end
    end
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedder)
    embedder
  end

  # Gives a service the vector of the fake model, as the refresh job does.
  def index_service(service, vector, model: FAKE_MODEL)
    Scheduling::ServiceIndex.store!(service, vector, model)
    service.reload
  end
end

RSpec.configure { |config| config.include ServiceEmbeddingHelpers }
