require 'timeout'

# Finds catalog services by meaning. The patient agent (or staff, or Copilot) gives a LIST of service mentions in one call; the mentions
# are embedded in one request and each one gets its nearest services of the account with a similarity score (Scheduling::ServiceIndex).
# A mention whose best score is below MIN_SCORE is "not in the catalog". There is no text search next to it: a hybrid of the old text
# search and the vector search was worse than the vector search alone (76% against 85% right first, 345 mentions of five clinics).
class Captain::Tools::Account::SearchSchedulingServicesService < Captain::Tools::Account::BaseAccountTool
  # Below this cosine similarity nothing in the catalog is the service of a mention. Calibrated on 345 mentions of five clinics
  # (299 with a service in the catalog, 46 without; Kazakh, abbreviations, typos, referrals with several services) embedded with
  # google/gemini-embedding-001 at 1536 numbers: at 0.66 a service that exists is found in 91% of the mentions (the right one is
  # among the answers in 88%, first in 79%) and a mention without a service is wrongly accepted in 44%; at 0.69, the best split of
  # the two groups, 22% of the existing services would be refused. A refused real service ends the conversation about it, an extra
  # candidate is read by the agent by its name and score, so the threshold keeps the real ones. Re-check it when the model changes.
  MIN_SCORE = 0.66
  # Services returned per mention when the caller gives no limit (the right one is in the first three for 95% of the mentions).
  DEFAULT_LIMIT = 5
  # Mentions of one call: a referral lists a handful of services; more would only be read again on every step.
  MAX_MENTIONS = 8
  # The embedding request of a call may take this long; then the tool says the search is unavailable.
  SEARCH_TIMEOUT_SECONDS = 12
  NOT_IN_CATALOG = 'not_in_catalog'.freeze
  FOUND = 'found'.freeze
  SEARCH_UNAVAILABLE = 'Service search is temporarily unavailable.'.freeze
  INDEX_NOT_READY = 'The service catalog is being prepared for search. Try again in a minute.'.freeze

  def self.name
    'search_scheduling_services'
  end

  description 'Find catalog services by meaning. Put every service of the request in queries (one string per mention): each ' \
              'mention gets its best catalog matches with a similarity score, or not_in_catalog when no service is close. ' \
              'A match does not confirm clinical eligibility or a MedElement route; to book, choose the specialist first with ' \
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
    mentions = normalize_mentions(queries)
    include_inactive = cast_boolean(include_inactive) && !agent_scope?
    if mentions.empty?
      return refine_query_payload(include_inactive) if agent_scope?

      return listing_payload(include_inactive, parse_offset(offset), parse_limit(limit))
    end

    search_payload(mentions, include_inactive: include_inactive, limit: mention_limit(limit))
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

  # queries may arrive as a list, a single string, or a JSON list in a string.
  def normalize_mentions(queries)
    list = queries.is_a?(String) ? parse_mention_string(queries) : Array(queries)
    list.map { |mention| mention.to_s.squish.first(Scheduling::ServiceIndex::MAX_MENTION_LENGTH) }.reject(&:blank?).uniq.first(MAX_MENTIONS)
  end

  def parse_mention_string(text)
    parsed = text.strip.start_with?('[') ? JSON.parse(text) : nil
    parsed.is_a?(Array) ? parsed : [text]
  rescue JSON::ParserError
    [text]
  end

  # The patient agent reads at most SERVICE_LIMIT services per mention, whatever limit it asks for.
  def mention_limit(limit)
    return parse_limit(limit, default: DEFAULT_LIMIT, max: Captain::Tools::Agent::CatalogPayload::SERVICE_LIMIT) if agent_scope?

    parse_limit(limit, default: DEFAULT_LIMIT)
  end

  def search_payload(mentions, include_inactive:, limit:)
    embedder = Captain::Llm::EmbeddingService.new(account_id: account.id)
    return tool_failure(INDEX_NOT_READY) unless index_ready?(embedder.embedding_model)

    results = nearest_services(embedder, mentions, include_inactive, limit)
    prices = price_rows_by_service(results.flat_map { |result| result[:hits].map(&:service) }.uniq(&:id))
    payload = results.map { |result| result_payload(result, prices) }
    agent_scope? ? compact_payload(results: payload) : formatted_search_payload(payload, mentions, include_inactive)
  end

  # [{ mention:, hits: [Scheduling::ServiceIndex::Hit] }] in the order of the mentions, the hits below MIN_SCORE dropped. One request
  # embeds all mentions.
  def nearest_services(embedder, mentions, include_inactive, limit)
    scope = include_inactive ? account.scheduling_services : account.scheduling_services.active
    vectors = Timeout.timeout(SEARCH_TIMEOUT_SECONDS) do
      embedder.get_embeddings(mentions, input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
    end
    hits_by_mention = Scheduling::ServiceIndex.nearest(scope, vectors, model: embedder.embedding_model, limit: limit)
    mentions.zip(hits_by_mention).map { |mention, hits| { mention: mention, hits: hits.select { |hit| hit.score >= MIN_SCORE } } }
  end

  # The catalog can be searched when its active services have vectors of the model in force. While none has (a new account, or a model
  # that was just changed) the refresh is queued at once and the caller is told to try again; a few services still waiting for theirs
  # simply are not found until the refresh job reaches them.
  def index_ready?(model)
    readiness = Scheduling::ServiceIndex.readiness(account.id, model)
    Scheduling::ServiceEmbeddingJob.enqueue(account.id, wait: 0) if readiness[:searchable] < readiness[:active]
    readiness[:active].zero? || readiness[:searchable].positive?
  end

  def result_payload(result, prices)
    hits = result[:hits]
    return { query: result[:mention], status: NOT_IN_CATALOG } if hits.empty?

    services = hits.map { |hit| hit_payload(hit, prices.fetch(hit.service.id, [])) }
    { query: result[:mention], status: FOUND, services: services }
  end

  def hit_payload(hit, prices)
    score = hit.score.round(2)
    return agent_service_payload(hit.service, prices).merge(score: score) if agent_scope?

    Scheduling::PayloadBuilder.service(hit.service, prices: []).merge(prices: prices, score: score)
  end

  # The patient agent reads a compact entry (see Captain::Tools::Agent::CatalogPayload), not the admin payload of the service.
  def agent_service_payload(service, links)
    components = service.name.to_s.include?('+') ? package_component_services(service) : []
    Captain::Tools::Agent::CatalogPayload.service(service, links, components: components.size < 2 ? [] : components)
  end

  def package_component_services(service)
    raw = service.name.to_s.split(':', 2).last.to_s
    parts = raw.split('+').map(&:strip).reject(&:blank?)
    return [] if parts.size < 2

    active_scope = account.scheduling_services.active.where.not(id: service.id)
    parts.filter_map do |part|
      candidates = Scheduling::ServiceSearch.new(scope: active_scope, query: part).call.limit(5).to_a
      match = candidates.find { |item| !item.name.to_s.include?('+') && !item.name.to_s.match?(/повторн/i) } ||
              candidates.find { |item| !item.name.to_s.include?('+') }
      next unless match

      { id: match.id, name: match.name, price: match.base_price }
    end.uniq { |item| item[:id] }
  rescue StandardError
    []
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

  # Staff and Copilot get the admin payload with the verification labels, one block per mention.
  def formatted_search_payload(results, mentions, include_inactive)
    formatted_payload(
      filters: { queries: mentions, include_inactive: include_inactive, min_score: MIN_SCORE },
      results: results,
      eligibility_status: 'unverified'
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
