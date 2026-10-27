# frozen_string_literal: true

# The vector index of the service catalog (one platform embedding model, see Captain::Llm::EmbeddingService): what a service is
# embedded as, which services need a new vector, and the services nearest to a list of mentions.
#
# The vector sits in scheduling_services.embedding next to the name of the model that made it and the checksum of the embedded text.
# Scheduling::Service ignores the column (a list of services must not carry 12 KB of numbers per row), so the vector is written and
# searched by SQL only. A vector counts only while its model is the one in force: vectors of two models are never compared.
module Scheduling::ServiceIndex
  # How many services one request to the embedding model carries (the service batch of the experiment: 64).
  BATCH_SIZE = Captain::Llm::EmbeddingService::BATCH_MAX_INPUTS
  # A mention longer than this is cut: it is a service name, not a message.
  MAX_MENTION_LENGTH = 300

  # service: a Scheduling::Service of the search (without its vector); score: cosine similarity to the mention (1.0 = the same
  # direction).
  Hit = Struct.new(:service, :score)

  module_function

  # The similarity below which no service of the catalog is the service of a mention, for one embedding model (config/llm.yml,
  # service_min_score). A score means something only for the model that made it: the same mentions score far lower with another model
  # (24% of the real services above the number of Gemini with text-embedding-3-large), and a search with the wrong number would tell
  # patients that most services do not exist. nil when the model was not calibrated.
  def min_score(model)
    value = Llm::Models::CONFIG.dig('models', model.to_s, 'service_min_score')
    value.nil? ? nil : Float(value)
  end

  def calibrated?(model)
    !min_score(model).nil?
  end

  # What a service is embedded as: "name | aliases | category", the parts that are empty left out. The description is not part of it:
  # the experiment gave no gain for it (MRR .904 with it, .906 without).
  def text(service)
    parts = [service.name.to_s.squish, alias_text(service.custom_attributes.to_h['aliases']), service.category.to_s.squish]
    parts.reject(&:blank?).join(' | ')
  end

  def alias_text(aliases)
    Array(aliases).flat_map { |value| value.to_s.split("\n") }.map(&:squish).reject(&:blank?).join('; ')
  end

  def checksum(service)
    Captain::Llm::EmbeddingService.checksum(text(service))
  end

  # The services of one account whose vector is missing, made by another model, or made from a text that is not the text of the
  # service any more.
  def stale_services(account_id, model)
    Scheduling::Service.where(account_id: account_id).find_each.select do |service|
      service.embedding_model != model || service.embedded_at.nil? || service.embedding_checksum != checksum(service)
    end
  end

  # Embeds the stale services of one account in batches (one request per batch) and stores each vector with its model and checksum.
  # Returns how many services got a new vector. A model without a calibrated threshold (see .min_score) indexes nothing: the search
  # could not use the vectors.
  def refresh!(account_id)
    embedder = Captain::Llm::EmbeddingService.new(account_id: account_id)
    model = embedder.embedding_model
    unless calibrated?(model)
      Rails.logger.warn("[Scheduling::ServiceIndex] account #{account_id}: #{model.inspect} has no service_min_score, services are not indexed")
      return 0
    end

    stale = stale_services(account_id, model)
    stale.each_slice(BATCH_SIZE) do |slice|
      texts = slice.map { |service| text(service) }
      vectors = embedder.get_embeddings(texts, input_type: Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE)
      slice.zip(texts, vectors).each { |service, text, vector| store!(service, vector, model, text: text) }
    end
    stale.size
  end

  # One UPDATE writes the vector with its model, checksum and time, so that a row is never half indexed. Only while the service still
  # has the text that was embedded: the row is locked and read again, and a service that was renamed meanwhile keeps its old state (its
  # save queued a new refresh). Returns whether the vector was stored.
  def store!(service, vector, model, text: self.text(service))
    stored = false
    Scheduling::Service.transaction do
      current = Scheduling::Service.lock.find_by(id: service.id)
      if current && self.text(current) == text
        Scheduling::Service.where(id: service.id).update_all( # rubocop:disable Rails/SkipsModelValidations
          ['embedding = ?::vector, embedding_model = ?, embedding_checksum = ?, embedded_at = ?',
           vector_literal(Captain::Llm::EmbeddingService.normalize(vector)), model, Captain::Llm::EmbeddingService.checksum(text), Time.current]
        )
        stored = true
      end
    end
    stored
  end

  # A service whose embedded text changed has no usable vector until the refresh stores a new one: the old vector describes the old text.
  def invalidate!(service_id)
    Scheduling::Service.where(id: service_id).update_all(embedded_at: nil) # rubocop:disable Rails/SkipsModelValidations
  end

  def vector_literal(vector)
    "[#{vector.map(&:to_f).join(',')}]"
  end

  # How many services of the scope can be found now (their vector is made by the model in force and is current) and how many there are.
  def readiness(scope, model)
    { total: scope.count, searchable: searchable(scope, model).count }
  end

  def searchable(scope, model)
    scope.where(embedding_model: model).where.not(embedded_at: nil)
  end

  # The nearest services to each query vector, best first, up to limit per vector: [[Hit, ...], ...] in the order of the vectors. One
  # query per vector reads the vectors of one account (an exact scan of a few hundred rows; no approximate index, so nothing is missed).
  # scope: the services that may be found (the active ones of an account, or all of them for staff). Only services whose vector was
  # made by `model` take part.
  def nearest(scope, vectors, model:, limit:)
    ready = searchable(scope, model)
    vectors.map { |vector| hits_for(ready, vector, limit) }
  end

  def hits_for(searchable, vector, limit)
    literal = Scheduling::Service.connection.quote(vector_literal(vector))
    distance = "scheduling_services.embedding <=> #{literal}::vector"
    columns = Scheduling::Service.column_names.map { |column| "scheduling_services.#{column}" }
    searchable.select(*columns, "1 - (#{distance}) AS vector_score").reorder(Arel.sql(distance), :id).limit(limit)
              .map { |service| Hit.new(service, service.vector_score.to_f) }
  end
end
