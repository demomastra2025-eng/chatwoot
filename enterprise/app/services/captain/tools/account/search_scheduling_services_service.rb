require 'timeout'

# Finds catalog services by meaning. The patient agent (or staff, or Copilot) gives a LIST of service mentions in one call; the mentions
# are embedded in one request and each one gets its nearest services of the account with a similarity score (Scheduling::ServiceIndex).
# The services of an answer are candidates: the caller reads their names and uses one only if it is the service asked for. A mention
# whose best score is below the threshold of the embedding model in force is "not in the catalog". There is no text search next to it: a
# hybrid of the old text search and the vector search was worse than the vector search alone (76% against 85% right first, 345 mentions
# of five clinics).
class Captain::Tools::Account::SearchSchedulingServicesService < Captain::Tools::Account::BaseAccountTool
  # The threshold is a property of the embedding model (config/llm.yml, service_min_score; Scheduling::ServiceIndex.min_score). For
  # google/gemini-embedding-001 at 1536 numbers it is 0.66, calibrated on 345 mentions of five clinics (299 with a service in the
  # catalog, 46 without; Kazakh, abbreviations, typos, referrals with several services): at 0.66 a service that exists is found in 91%
  # of the mentions (the right one is among the answers in 88%, first in 79%) and a mention without a service still gets an answer in
  # 44%; at 0.69, the best split of the two groups, 22% of the existing services would be refused. A refused real service ends the
  # conversation about it, an extra candidate is read by the agent by its name and score, so the threshold keeps the real ones.
  #
  # Services returned per mention when the caller gives no limit: the right one is in the first three for 95% of the mentions for the
  # patient agent; staff and Copilot read more.
  AGENT_DEFAULT_LIMIT = 3
  STAFF_DEFAULT_LIMIT = 5
  # A service whose score is more than this below the best score of its mention is not offered (a closer service exists, and the
  # twins of a name, "with" and "without" something, score within a few hundredths of each other).
  SCORE_BAND = 0.05
  # All services of one answer: more would only be read again on every step. Every mention keeps its best service.
  ENTRY_CAP = 15
  # Mentions of one call: a referral lists a handful of services; the rest are named in queries_not_searched.
  MAX_MENTIONS = 8
  # The embedding request of a call may take this long; then the tool says the search is unavailable.
  SEARCH_TIMEOUT_SECONDS = 12
  NOT_IN_CATALOG = 'not_in_catalog'.freeze
  # Nothing close was found, but some services of the catalog are not searchable yet (a new catalog, or services that were just
  # renamed): the service may exist.
  CATALOG_UPDATING = 'catalog_updating'.freeze
  FOUND = 'found'.freeze
  SEARCH_UNAVAILABLE = 'Service search is temporarily unavailable.'.freeze
  INDEX_NOT_READY = 'The service catalog is being prepared for search. Try again in a minute.'.freeze

  def self.name
    'search_scheduling_services'
  end

  description 'Find catalog services by meaning. Put every service of the request in queries (one string per mention): each mention ' \
              'gets candidate services with a similarity score, best first, or not_in_catalog when none is close. A candidate is the ' \
              'service asked for only when its name says so (with or without something, the body part, first or repeat visit must ' \
              'match). A match does not confirm clinical eligibility or a MedElement route; to book, choose the specialist first with ' \
              'search_scheduling_resources. Without queries the catalog is listed page by page (staff only)'
  param :queries, type: :array,
                  desc: 'Service mentions, one string each: a name, an abbreviation or the patient\'s own words. All services of ' \
                        'one request go in this one list',
                  required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive services', required: false
  param :limit, type: :number, desc: 'Maximum number of services per mention', required: false
  param :offset, type: :number, desc: 'Listing without queries only: pagination offset; pass next_offset of the previous answer',
                 required: false

  def execute(queries: nil, include_inactive: false, limit: nil, offset: nil)
    mentions, skipped = normalize_mentions(queries)
    include_inactive = cast_boolean(include_inactive) && !agent_scope?
    if mentions.empty?
      return refine_query_payload(include_inactive) if agent_scope?

      return listing_payload(include_inactive, parse_offset(offset), parse_limit(limit))
    end

    search_payload(mentions, skipped, include_inactive: include_inactive, limit: mention_limit(limit))
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, Timeout::Error => e
    Rails.logger.error("[#{self.class.name}] embedding search failed: #{e.class}: #{e.message}")
    tool_failure(SEARCH_UNAVAILABLE)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  # [mentions to search, mentions left out]: queries may arrive as a list, a single string, or a JSON list in a string.
  def normalize_mentions(queries)
    list = queries.is_a?(String) ? parse_mention_string(queries) : Array(queries)
    mentions = list.map { |mention| mention.to_s.squish.first(Scheduling::ServiceIndex::MAX_MENTION_LENGTH) }.reject(&:blank?).uniq
    [mentions.first(MAX_MENTIONS), mentions.drop(MAX_MENTIONS)]
  end

  def parse_mention_string(text)
    parsed = text.strip.start_with?('[') ? JSON.parse(text) : nil
    parsed.is_a?(Array) ? parsed : [text]
  rescue JSON::ParserError
    [text]
  end

  # The patient agent reads at most SERVICE_LIMIT services per mention, whatever limit it asks for.
  def mention_limit(limit)
    return parse_limit(limit, default: AGENT_DEFAULT_LIMIT, max: Captain::Tools::Agent::CatalogPayload::SERVICE_LIMIT) if agent_scope?

    parse_limit(limit, default: STAFF_DEFAULT_LIMIT)
  end

  def search_payload(mentions, skipped, include_inactive:, limit:)
    embedder = Captain::Llm::EmbeddingService.new(account_id: account.id)
    min_score = Scheduling::ServiceIndex.min_score(embedder.embedding_model)
    return not_calibrated(embedder.embedding_model) if min_score.nil?

    scope = include_inactive ? account.scheduling_services : account.scheduling_services.active
    state = catalog_state(scope, embedder.embedding_model)
    return tool_failure(INDEX_NOT_READY) if state == :not_ready

    results = shaped(nearest_services(embedder, scope, mentions, min_score, limit), limit)
    answer = answer_payload(results, package_components(embedder, scope, results, min_score), state == :partial)
    return compact_search_payload(answer, skipped) if agent_scope?

    formatted_search_payload(answer, mentions, skipped, include_inactive, min_score)
  end

  # :ready (every service of the scope has a vector of the model in force), :partial (some wait for theirs: the others are searched, a
  # mention that matches nothing is not "not in the catalog") or :not_ready (none has one yet). Anything but :ready queues the refresh.
  def catalog_state(scope, model)
    readiness = Scheduling::ServiceIndex.readiness(scope, model)
    return :ready if readiness[:searchable] == readiness[:total]

    Scheduling::ServiceEmbeddingJob.enqueue(account.id, wait: 0)
    readiness[:searchable].zero? ? :not_ready : :partial
  end

  # No search with a model whose threshold was not calibrated: the scores of another model say nothing about the services.
  def not_calibrated(model)
    Rails.logger.error("[#{self.class.name}] #{model.inspect} has no service_min_score: the service search is off until it is calibrated")
    tool_failure(INDEX_NOT_READY)
  end

  def answer_payload(results, components, incomplete)
    prices = price_rows_by_service(results.flat_map { |result| result[:hits].map(&:service) }.uniq(&:id))
    results.map { |result| result_payload(result, prices, components, catalog_incomplete: incomplete) }
  end

  # [{ mention:, hits: [Scheduling::ServiceIndex::Hit] }] in the order of the mentions, the hits below the threshold dropped. One request
  # embeds all mentions.
  def nearest_services(embedder, scope, mentions, min_score, limit)
    vectors = embed(embedder, mentions)
    hits_by_mention = Scheduling::ServiceIndex.nearest(scope, vectors, model: embedder.embedding_model, limit: limit)
    mentions.zip(hits_by_mention).map { |mention, hits| { mention: mention, hits: hits.select { |hit| hit.score >= min_score } } }
  end

  def embed(embedder, texts)
    Timeout.timeout(SEARCH_TIMEOUT_SECONDS) do
      embedder.get_embeddings(texts, input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
    end
  end

  def shaped(results, limit)
    Captain::Tools::Account::ServiceMatchSelection.new(band: SCORE_BAND, cap: ENTRY_CAP).call(results, limit)
  end

  def result_payload(result, prices, components, catalog_incomplete:)
    hits = result[:hits]
    return { query: result[:mention], status: catalog_incomplete ? CATALOG_UPDATING : NOT_IN_CATALOG } if hits.empty?

    services = hits.map { |hit| hit_payload(hit, prices.fetch(hit.service.id, []), components.fetch(hit.service.id, [])) }
    { query: result[:mention], status: FOUND, services: services }
  end

  def hit_payload(hit, prices, components)
    score = hit.score.round(2)
    return Captain::Tools::Agent::CatalogPayload.service(hit.service, prices, components: components).merge(score: score) if agent_scope?

    Scheduling::PayloadBuilder.service(hit.service, prices: []).merge(prices: prices, score: score)
  end

  # The parts of the package services among the answers (patient agent only): see Captain::Tools::Account::ServicePackageComponents.
  def package_components(embedder, scope, results, min_score)
    return {} unless agent_scope?

    components = Captain::Tools::Account::ServicePackageComponents.new(
      scope: scope, model: embedder.embedding_model, min_score: min_score, embed: ->(texts) { embed(embedder, texts) }
    )
    components.call(results.flat_map { |result| result[:hits].map(&:service) }.uniq(&:id))
  rescue Captain::Llm::EmbeddingService::EmbeddingsError, Timeout::Error => e
    Rails.logger.warn("[#{self.class.name}] package parts not resolved: #{e.class}: #{e.message}")
    {}
  end

  # A price row is a recorded link between a service and a resource, never proof that the resource may perform the
  # service. Only the active rows of the service's own account are listed. Staff and Copilot see each row labelled as
  # unverified; the patient agent gets a compact entry without that label (a label that names no action gave the model a reason
  # to doubt the price and to hand the conversation over).
  def price_rows_by_service(services)
    return {} if services.empty?

    linked_prices(services).group_by(&:service_id).transform_values do |prices|
      next agent_price_links(prices) if agent_scope?

      prices.map { |price| Scheduling::PayloadBuilder.service_price(price).merge(service_eligibility_status: 'price_link_unverified') }
    end
  end

  def linked_prices(services)
    scope = Scheduling::ServicePrice.active.joins(:resource)
                                    .where(account_id: account.id, service_id: services.map(&:id))
                                    .where(scheduling_resources: { account_id: account.id, active: true })
    scope = scope.select('scheduling_service_prices.*, scheduling_resources.name AS resource_name') if agent_scope?
    scope.order(:id)
  end

  def agent_price_links(prices)
    prices.map { |price| { resource_id: price.resource_id, resource_name: price.resource_name, price: price.price } }
  end

  # The patient agent re-reads the answer on every step: one line, the mentions that were left out named.
  def compact_search_payload(results, skipped)
    compact_payload({ results: results, queries_not_searched: skipped.presence }.compact)
  end

  # Staff and Copilot get the admin payload with the verification labels, one block per mention.
  def formatted_search_payload(results, mentions, skipped, include_inactive, min_score)
    formatted_payload(
      {
        filters: { queries: mentions, include_inactive: include_inactive, min_score: min_score },
        results: results,
        queries_not_searched: skipped.presence,
        eligibility_status: 'unverified'
      }.compact
    )
  end

  # The catalog in name order, page by page, for staff and Copilot (the patient agent never lists it, see refine_query_payload).
  def listing_payload(include_inactive, offset, limit)
    services = (include_inactive ? account.scheduling_services : account.scheduling_services.active).ordered
    total_count = services.count
    page = services.offset(offset).limit(limit).to_a
    prices = price_rows_by_service(page)
    records = page.map { |service| Scheduling::PayloadBuilder.service(service, prices: []).merge(prices: prices.fetch(service.id, [])) }
    next_offset = offset + records.length
    has_more = next_offset < total_count
    formatted_payload(
      filters: { include_inactive: include_inactive, offset: offset },
      total_count: total_count, returned_count: records.length, has_more: has_more, next_offset: (next_offset if has_more),
      page_status: records.empty? && total_count.positive? ? 'offset_out_of_range' : 'returned',
      eligibility_status: 'unverified', services: records
    )
  end

  # An empty list of the patient agent never lists the catalog: the answer says so and names the categories to search by.
  def refine_query_payload(include_inactive)
    services = include_inactive ? account.scheduling_services : account.scheduling_services.active
    categories = services.where.not(category: [nil, '']).distinct.order(:category)
                         .limit(Captain::Tools::Agent::CatalogPayload::CATEGORY_HINT_LIMIT).pluck(:category)
    compact_payload({ status: 'queries_required', total_count: services.count, categories: categories.presence,
                      instruction: Captain::Tools::Agent::CatalogPayload::REFINE_QUERY_INSTRUCTION }.compact)
  end
end
