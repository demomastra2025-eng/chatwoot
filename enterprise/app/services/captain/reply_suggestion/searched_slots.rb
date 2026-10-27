# frozen_string_literal: true

# The free starts that the slot reads of one reply suggestion run returned (search_available_slots, search_booking_options, get_scheduling_resource_availability),
# read from the cache of the reads of the run (see Captain::Runtime::ToolWrapper#cache_suggestion_read_result). A start counts as
# returned when the answer the agent read lists it for that specialist: a time of a specialist-day of the compact answer ({ resource_id,
# date, times, more }, also under next_available) or a slot with its own start. The times of a day are a sample (at most five, the rest
# only counted in `more`), so a start that is not listed was not returned, whether it is free or not: the agent searches that exact time
# (from = to) and the answer lists it.
#
# #specialists gives, per specialist, the name the answer wrote with the times it listed for that specialist, so a draft that puts a
# time under a name can be checked against the specialist's own list (Captain::ReplySuggestion::DraftTimes.misattributed).
class Captain::ReplySuggestion::SearchedSlots
  SEARCH_TOOL = 'search_available_slots'
  READ_TOOLS = [SEARCH_TOOL, 'search_booking_options', 'get_scheduling_resource_availability'].freeze
  # The reads that name specialists without listing their free times: a specialist found by the catalog is known by name too.
  CATALOG_TOOLS = %w[search_scheduling_resources list_scheduling_resources].freeze
  # The answer of a tool is JSON in a JSON string, in a result hash: this many levels are opened.
  MAX_DEPTH = 7
  CLOCK = /\A([01]?\d|2[0-3]):([0-5]\d)\z/

  def initialize(context)
    @context = context.to_h
  end

  # Whether the slot reads of the run returned this start of the specialist. starts_at: a time or a time string; timezone: the zone of
  # the specialist, whose clock the dates and times of the answer are in.
  def returned?(resource_id:, starts_at:, timezone:)
    local = starts_at.in_time_zone(timezone)
    days.include?([resource_id.to_i, local.strftime('%Y-%m-%d'), local.strftime('%H:%M')]) ||
      instants.include?([resource_id.to_i, local.to_i])
  end

  # Whether the run searched free times at all.
  def searched?
    days.any? || instants.any?
  end

  # { resource_id => { name: 'Князова Жанат', times: ['09:00', '09:30'] } } of every specialist the reads of the run name: the
  # specialist-days and the slots of the slot reads with the starts they list (a clock of the specialist, "HH:MM", of any day), and the
  # specialists of the catalog reads, which have no times unless a slot read lists some.
  def specialists
    read_data
    @specialists.transform_values { |entry| { name: entry[:name], times: entry[:times].to_a.sort } }
  end

  private

  # [resource_id, 'YYYY-MM-DD', 'HH:MM'] of every listed start.
  def days
    read_data
    @days
  end

  # [resource_id, epoch seconds] of every slot that carries its own start.
  def instants
    read_data
    @instants
  end

  def read_data
    return if @days

    @days = Set.new
    @instants = Set.new
    @specialists = Hash.new { |hash, id| hash[id] = { name: nil, times: Set.new } }
    read_results.each { |result| collect(result, 0) }
    catalog_results.each { |result| collect_catalog(result, 0) }
  end

  def read_results
    results_of(READ_TOOLS)
  end

  def catalog_results
    results_of(CATALOG_TOOLS)
  end

  def results_of(tools)
    cache = @context.fetch(Captain::Runtime::ToolWrapper::SUGGESTION_READ_CACHE_KEY, nil).to_h
    cache.values.filter_map do |entry|
      entry = entry.to_h.with_indifferent_access
      entry[:result] if tools.include?(entry[:tool].to_s)
    end
  end

  def collect(node, depth)
    return if depth > MAX_DEPTH

    case node
    when Hash then collect_hash(node.with_indifferent_access, depth)
    when Array then node.each { |item| collect(item, depth + 1) }
    when String then collect_json(node, depth)
    end
  end

  def collect_hash(hash, depth)
    add_day(hash) if hash[:times].is_a?(Array) && hash[:date].present?
    add_instant(hash) if hash[:starts_at].present?
    hash.each_value { |value| collect(value, depth + 1) }
  end

  def collect_json(text, depth)
    stripped = text.lstrip
    return unless stripped.start_with?('{', '[')

    collect(JSON.parse(stripped), depth + 1)
  rescue JSON::ParserError
    nil
  end

  def add_day(hash)
    resource_id = hash[:resource_id].to_i
    name_specialist(resource_id, hash[:name])
    hash[:times].each do |time|
      match = CLOCK.match(time.to_s.strip)
      next unless match

      clock = format('%<hour>02d:%<minute>s', hour: match[1].to_i, minute: match[2])
      @days << [resource_id, hash[:date].to_s, clock]
      @specialists[resource_id][:times] << clock
    end
  end

  def add_instant(hash)
    start = Time.iso8601(hash[:starts_at].to_s)
    resource_id = hash[:resource_id].to_i
    @instants << [resource_id, start.to_i]
    name_specialist(resource_id, hash[:resource_name])
    zone = ActiveSupport::TimeZone[hash[:timezone].to_s]
    @specialists[resource_id][:times] << (zone ? start.in_time_zone(zone) : start).strftime('%H:%M')
  rescue ArgumentError
    nil
  end

  # The specialists of a catalog read: { resources: [{ id, name, ... }] } at any depth of the answer.
  def collect_catalog(node, depth)
    return if depth > MAX_DEPTH

    case node
    when Hash then collect_catalog_hash(node.with_indifferent_access, depth)
    when Array then node.each { |item| collect_catalog(item, depth + 1) }
    when String then collect_catalog_json(node, depth)
    end
  end

  def collect_catalog_hash(hash, depth)
    Array(hash[:resources]).each do |row|
      row = row.to_h.with_indifferent_access
      name_specialist(row[:id].to_i, row[:name]) if row[:id].present?
    end
    hash.each_value { |value| collect_catalog(value, depth + 1) }
  end

  def collect_catalog_json(text, depth)
    stripped = text.lstrip
    return unless stripped.start_with?('{', '[')

    collect_catalog(JSON.parse(stripped), depth + 1)
  rescue JSON::ParserError
    nil
  end

  def name_specialist(resource_id, name)
    return if resource_id.zero? || name.blank?

    @specialists[resource_id][:name] ||= name.to_s.squish
  end
end
