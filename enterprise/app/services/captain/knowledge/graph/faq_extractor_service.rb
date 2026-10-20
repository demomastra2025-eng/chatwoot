# frozen_string_literal: true

class Captain::Knowledge::Graph::FaqExtractorService
  include Captain::Knowledge::Graph::Lexicon

  def self.sync_response!(response)
    new(response).sync!
  end

  def self.sync_account!(account)
    account.captain_assistant_responses.approved.find_each { |response| sync_response!(response) }
  end

  def initialize(response)
    @response = response
    @account = response.account
    @upserter = Captain::Knowledge::Graph::UpsertService.new(
      account: @account,
      assistant_id: response.assistant_id,
      visibility: response.visibility
    )
  end

  def sync!
    @upserter.remove_response_evidence!(@response.id)
    return unless @response.approved?

    russian_body = @response.answer.to_s.split(/\bKZ:\s*/i).first.to_s.sub(/\ARU:\s*/i, '').strip
    full_text = "#{@response.question}\n#{russian_body}"
    source_key = "faq:#{@response.id}"

    link_entities(
      specialists: upsert_specialists(russian_body, source_key),
      specialties: upsert_specialties(full_text, source_key),
      services: upsert_services(full_text, russian_body, source_key),
      locations: upsert_locations(russian_body, source_key),
      symptoms: upsert_symptoms(full_text, source_key)
    )
  end

  private

  def upsert_specialties(text, source_key)
    lower = text.downcase.tr('ё', 'е')
    base_attrs = extract_segment_attributes(text)
    SPECIALTY_DICTIONARY.filter_map do |canonical, variants|
      next unless variants.any? { |v| lower.include?(v) }

      @upserter.upsert_node(
        node_type: :specialty, canonical_name: canonical, source_key: source_key,
        aliases: variants, attributes: base_attrs, response_id: @response.id
      )
    end
  end

  def upsert_services(full_text, answer_body, source_key)
    SERVICE_PATTERNS.filter_map do |canonical, regex, aliases|
      next unless full_text.match?(regex)

      segment = matching_sentences(answer_body, regex).presence || answer_body
      attrs = extract_segment_attributes(answer_body).merge(extract_segment_attributes(segment, service_regex: regex))
      @upserter.upsert_node(
        node_type: :service, canonical_name: canonical, source_key: source_key,
        aliases: aliases, attributes: attrs, response_id: @response.id
      )
    end
  end

  def upsert_specialists(answer_body, source_key)
    segments = split_clauses(answer_body)
    found = []
    answer_body.scan(PERSON_NAME_REGEX) do |last_name, first_name, middle_name|
      next if NAME_STOP_WORDS.include?(last_name) || NAME_STOP_WORDS.include?(first_name)

      name_parts = [last_name, first_name, middle_name].compact
      clause = segments.find { |seg| seg.include?(name_parts.join(' ')) } || answer_body
      node = build_specialist_node(name_parts, answer_body, clause, source_key)
      found << [node, clause] if node
    end
    found
  end

  def build_specialist_node(name_parts, answer_body, clause, source_key)
    full_name = name_parts.join(' ')
    attrs = extract_segment_attributes(clause).merge(extract_segment_global_fallback(answer_body, clause))
    @upserter.upsert_node(
      node_type: :specialist, canonical_name: full_name, source_key: source_key,
      aliases: [name_parts.first, name_parts.first(2).join(' ')].uniq, attributes: attrs, response_id: @response.id
    )
  end

  def extract_segment_global_fallback(answer_body, clause)
    global_attrs = extract_segment_attributes(answer_body)
    local_attrs = extract_segment_attributes(clause)
    global_attrs.slice(:age_policy, :cabinet, :primary_price_kzt, :repeat_price_kzt).reject { |k, _| local_attrs.key?(k) }
  end

  def upsert_locations(answer_body, source_key)
    answer_body.scan(/каб(?:инет|\.)?\s*№?\s*(\d{2,4})/i).flatten.uniq.filter_map do |cab_num|
      @upserter.upsert_node(
        node_type: :location, canonical_name: "каб. №#{cab_num}", source_key: source_key,
        aliases: ["кабинет #{cab_num}", "каб #{cab_num}", cab_num],
        attributes: { cabinet: "каб. №#{cab_num}" }, response_id: @response.id
      )
    end
  end

  def upsert_symptoms(full_text, source_key)
    matches = full_text.scan(/(?:при\s+|выявления\s+)([^.?!:;()]{5,90})/i).flatten
    matches.flat_map { |chunk| chunk.split(/,| и /) }
           .map(&:squish)
           .select { |item| item.length.between?(4, 45) && item.match?(/травм|перелом|ушиб|бол|сустав|тромб|беремен/i) }
           .uniq
           .filter_map do |symptom_text|
      @upserter.upsert_node(
        node_type: :symptom, canonical_name: symptom_text, source_key: source_key,
        aliases: [symptom_text], attributes: {}, response_id: @response.id
      )
    end
  end

  def link_entities(specialists:, specialties:, services:, locations:, symptoms:)
    specialists.each do |specialist_node, clause|
      link_specialist_edges(specialist_node, clause, specialties: specialties, services: services, locations: locations)
    end
    link_symptom_edges(specialties + specialists.map(&:first), symptoms)
  end

  def link_specialist_edges(specialist_node, clause, specialties:, services:, locations:)
    clause_lower = clause.downcase.tr('ё', 'е')
    matched_specs = specialties.select { |spec| Array(SPECIALTY_DICTIONARY[spec.canonical_name]).any? { |v| clause_lower.include?(v) } }
    (matched_specs.presence || specialties).each do |spec_node|
      @upserter.upsert_edge(source_node: specialist_node, target_node: spec_node, relation_type: :has_specialty, response_id: @response.id)
    end
    services.each do |service_node|
      @upserter.upsert_edge(source_node: specialist_node, target_node: service_node, relation_type: :performs_service, response_id: @response.id)
    end
    link_specialist_locations(specialist_node, clause, locations)
  end

  def link_specialist_locations(specialist_node, clause, locations)
    locations.each do |loc_node|
      cab_num = loc_node.canonical_name[/\d+/]
      next unless clause.include?(cab_num.to_s) || locations.one?

      @upserter.upsert_edge(source_node: specialist_node, target_node: loc_node, relation_type: :located_in, response_id: @response.id)
    end
  end

  def link_symptom_edges(actors, symptoms)
    actors.each do |actor_node|
      symptoms.each do |symptom_node|
        @upserter.upsert_edge(source_node: actor_node, target_node: symptom_node, relation_type: :treats_symptom, response_id: @response.id)
      end
    end
  end

  def extract_segment_attributes(text, service_regex: nil)
    attrs = { available: !negative_availability?(text, service_regex) }
    attrs.merge!(extract_prices(text)) if attrs[:available]
    attrs[:age_policy] = extract_age_policy(text)
    attrs[:cabinet] = "каб. №#{Regexp.last_match(1)}" if text =~ /каб(?:инет|\.)?\s*№?\s*(\d{2,4})/i
    attrs[:experience_years] = Regexp.last_match(1).to_i if text =~ /стаж\s+(?:более\s+|около\s+)?(\d+)\s+(?:лет|года|год)/i
    attrs[:preparation] = matching_sentences(text, /натощак|подготовк|часов\s+без\s+еды|не\s+пить|перед\s+исследованием/i).presence
    attrs[:contraindications] = matching_sentences(text, /противопоказан|кардиостимулятор|металлических\s+имплант|триместр/i).presence
    attrs.compact
  end

  def negative_availability?(text, service_regex)
    target = service_regex ? matching_sentences(text, service_regex) : text
    target.to_s.match?(/не\s+проводит|не\s+делаем|не\s+выполняет|нет\s+в\s+клинике/i)
  end

  def extract_prices(text)
    prices = {}
    if text =~ /первичн\p{L}*(?:\s+при[её]м)?\s*[—\-:]\s*([\d\s]{4,9})\s*(?:₸|тг|тенге)/i
      prices[:primary_price_kzt] = normalize_amount(Regexp.last_match(1))
    end
    if text =~ /повторн\p{L}*(?:\s+при[её]м)?\s*[—\-:]\s*([\d\s]{4,9})\s*(?:₸|тг|тенге)/i
      prices[:repeat_price_kzt] = normalize_amount(Regexp.last_match(1))
    end
    prices[:primary_price_kzt] = normalize_amount(Regexp.last_match(1)) if prices.empty? && text =~ /(\d[\d\s]{2,8})\s*(?:₸|тг|тенге)/i
    prices.compact
  end

  def normalize_amount(raw)
    value = raw.to_s.gsub(/\D/, '').to_i
    value.positive? ? value : nil
  end

  def extract_age_policy(text)
    if text.match?(/(?:от|с)\s*18\s*лет|взросл\p{L}+\s*\(\s*(?:от|с)\s*18\s*лет\s*\)/i)
      { 'min_age_years' => 18, 'accepts_children' => false, 'summary' => 'с 18 лет (взрослые)' }
    elsif text.match?(/с\s+рождения\s+до\s+18\s+лет|с\s+0\s+лет|детск\p{L}+\s+(?:врач|кардиолог|при[её]м)/i)
      { 'min_age_years' => 0, 'max_age_years' => 18, 'accepts_children' => true, 'summary' => 'с рождения до 18 лет (дети)' }
    end
  end

  def matching_sentences(text, regex)
    text.to_s.split(/(?<=[.?!;])\s+/).grep(regex).join(' ')
  end

  def split_clauses(text)
    numbered = text.to_s.split(/(?=\b\d+\)\s)/).map(&:strip).reject(&:blank?)
    return numbered if numbered.size > 1

    text.to_s.split(/\n+/).map(&:strip).reject(&:blank?)
  end
end
