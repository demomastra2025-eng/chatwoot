# frozen_string_literal: true

# The free starts that the slot reads of one reply suggestion run returned (search_available_slots, get_scheduling_resource_availability),
# read from the cache of the reads of the run (see Captain::Runtime::ToolWrapper#cache_suggestion_read_result). A start counts as
# returned when the answer the agent read lists it for that specialist: a time of a specialist-day of the compact answer ({ resource_id,
# date, times, more }, also under next_available) or a slot with its own start. The times of a day are a sample (at most five, the rest
# only counted in `more`), so a start that is not listed was not returned, whether it is free or not: the agent searches that exact time
# (from = to) and the answer lists it.
class Captain::ReplySuggestion::SearchedSlots
  READ_TOOLS = %w[search_available_slots get_scheduling_resource_availability].freeze
  # The answer of a tool is JSON in a JSON string, in a result hash: this many levels are opened.
  MAX_DEPTH = 5
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
    read_results.each { |result| collect(result, 0) }
  end

  def read_results
    cache = @context.fetch(Captain::Runtime::ToolWrapper::SUGGESTION_READ_CACHE_KEY, nil).to_h
    cache.values.filter_map do |entry|
      entry = entry.to_h.with_indifferent_access
      entry[:result] if READ_TOOLS.include?(entry[:tool].to_s)
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
    hash[:times].each do |time|
      match = CLOCK.match(time.to_s.strip)
      @days << [resource_id, hash[:date].to_s, format('%<hour>02d:%<minute>s', hour: match[1].to_i, minute: match[2])] if match
    end
  end

  def add_instant(hash)
    @instants << [hash[:resource_id].to_i, Time.iso8601(hash[:starts_at].to_s).to_i]
  rescue ArgumentError
    nil
  end
end
