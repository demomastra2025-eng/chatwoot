# frozen_string_literal: true

# Writes an appointment or deal summary (the hash of Captain::ContextSummary) as one compact English line for the agent prompt,
# for example "upcoming: Thu 15.10.2026 10:30, «Приём терапевта», Иванов Алексей; no past or cancelled appointments".
# The data values (titles, names) stay as stored. Pure: no database and no clock. It only reads the hash and never changes
# it, because the hash is the shared contract of outbound text, Liquid drops, custom tools and the playground.
#
# An internal number ("#101") is written only when a tool bound for the run takes that record's id (Captain::PromptNumbers).
class Captain::PromptSummaryText
  Entry = Struct.new(:label, :group, :items)

  APPOINTMENT_GROUPS = %w[upcoming past cancelled].freeze
  DEFAULT_APPOINTMENT_STATUSES = {
    'upcoming' => %w[scheduled confirmed], 'past' => %w[completed], 'cancelled' => %w[cancelled]
  }.freeze
  STATUS_WORDS = { 'no_show' => 'no-show' }.freeze
  CLIENT_DEAL_GROUPS = %w[open won lost].freeze
  UNKNOWN_CLOSE_TIME = 'created_at_fallback_event_time_unknown'

  class << self
    # The summary as text, or nil when the hash is not a summary shape this class knows.
    def render(summary, time_zone: nil, bound_tool_ids: nil)
      return unless summary.is_a?(Hash)

      new(summary.deep_stringify_keys, time_zone: time_zone, bound_tool_ids: bound_tool_ids).render
    end
  end

  def initialize(summary, time_zone:, bound_tool_ids:)
    @summary = summary
    @time_zone = time_zone
    @bound_tool_ids = bound_tool_ids
  end

  def render
    case @summary['kind']
    when 'appointments' then appointments_text
    when 'deals' then deals_text
    else client_deals_text
    end
  end

  private

  def appointments_text
    groups = groups_by_key('key')
    entries = APPOINTMENT_GROUPS.map do |key|
      Entry.new(key, groups[key], rendered_items(groups[key], 'items') { |item| appointment_item(item, key) })
    end
    compose(entries, 'appointments')
  end

  def deals_text
    groups = groups_by_key('key')
    show_pipeline = several_pipelines?(groups.values.flat_map { |group| Array(group['items']) })
    entries = { 'active' => 'open', 'history' => 'closed' }.map do |key, label|
      items = rendered_items(groups[key], 'items') do |card|
        deal_item(card, open: key == 'active', show_outcome: true, show_pipeline: show_pipeline)
      end
      Entry.new(label, groups[key], items)
    end
    compose(entries, 'deals')
  end

  def client_deals_text
    groups = groups_by_key('status')
    return unless groups.keys.intersect?(CLIENT_DEAL_GROUPS)

    show_pipeline = several_pipelines?(groups.values.flat_map { |group| Array(group['deals']) })
    entries = CLIENT_DEAL_GROUPS.map do |status|
      items = rendered_items(groups[status], 'deals') do |card|
        deal_item(card, open: status == 'open', show_outcome: false, show_pipeline: show_pipeline)
      end
      Entry.new(status, groups[status], items)
    end
    compose(entries, 'deals')
  end

  # The groups with rows, each as "label: row; row (and N more)", then one part naming the empty groups.
  def compose(entries, noun)
    listed, empty = entries.partition { |entry| entry.items.any? }
    parts = listed.map { |entry| group_text(entry) }
    parts << empty_text(empty.map(&:label), noun, entries.size) if empty.any?
    parts.join('; ')
  end

  def group_text(entry)
    hidden = entry.group['total'].to_i - entry.items.size
    "#{entry.label}: #{entry.items.join('; ')}#{" (and #{hidden} more)" if hidden.positive?}"
  end

  def empty_text(labels, noun, group_count)
    labels.size == group_count ? "no #{noun}" : "no #{labels.join(' or ')} #{noun}"
  end

  def groups_by_key(key_name)
    Array(@summary['groups']).select { |group| group.is_a?(Hash) }.index_by { |group| group[key_name].to_s }
  end

  def rendered_items(group, items_key)
    return [] if group.blank?

    Array(group[items_key]).select { |item| item.is_a?(Hash) }.filter_map { |item| yield(item).presence }
  end

  def appointment_item(item, group_key)
    moment = [weekday(item['date']), text(item['date']), text(item['time'])].compact_blank.join(' ')
    details = [moment, quoted(item['service']), text(item['doctor'])].compact_blank.join(', ')
    return if details.blank?

    "#{numbered(:appointment, item['id'], details)}#{appointment_status_note(item, group_key)}#{reschedule_note(item['reschedule'])}"
  end

  # The status is written only when it is not the usual one of the group (an upcoming appointment is scheduled, a past one is completed).
  def appointment_status_note(item, group_key)
    status = text(item['status'])
    return if status.blank? || DEFAULT_APPOINTMENT_STATUSES.fetch(group_key, []).include?(status)

    " (#{STATUS_WORDS.fetch(status, status)})"
  end

  # A move that the provider has not confirmed yet is a request, never the time of the visit.
  def reschedule_note(reschedule)
    return unless reschedule.is_a?(Hash)

    requested = [text(reschedule['requested_date']), text(reschedule['requested_time'])].compact_blank.join(' ')
    requested.present? ? " (move to #{requested} requested, not confirmed)" : ' (a move was requested, not confirmed)'
  end

  def deal_item(card, open:, show_outcome:, show_pipeline:)
    place = open ? open_deal_place(card, show_pipeline) : closed_deal_place(card, show_outcome)
    details = [quoted(card['title']), *place, [text(card['amount']), text(card['currency'])].compact_blank.join(' ')].compact_blank.join(', ')
    details.present? ? numbered(:deal, card['id'], details) : nil
  end

  def open_deal_place(card, show_pipeline)
    stage = quoted(card['stage'])
    pipeline = quoted(card['pipeline']) if show_pipeline
    [("stage #{stage}" if stage), ("pipeline #{pipeline}" if pipeline)]
  end

  def closed_deal_place(card, show_outcome)
    [[(deal_outcome(card) if show_outcome), deal_closed_on(card)].compact_blank.join(' ')]
  end

  def deal_outcome(card)
    outcome = card['outcome'].to_s
    return outcome if %w[won lost].include?(outcome)

    card['archived_at'].present? ? 'archived' : 'closed'
  end

  # The day the deal was closed or archived; nothing when the provider data only gives a creation date to sort by.
  def deal_closed_on(card)
    return if card['history_at'].blank? || card['history_at_source'] == UNKNOWN_CLOSE_TIME

    time = Captain::PromptClock.parse_time(card['history_at'])
    Captain::PromptClock.format_date(time, @time_zone) if time
  end

  def several_pipelines?(cards)
    cards.filter_map { |card| text(card['pipeline']) if card.is_a?(Hash) }.uniq.size > 1
  end

  def numbered(kind, id, details)
    return details unless id.present? && Captain::PromptNumbers.shown?(kind, @bound_tool_ids)

    "##{id} #{details}"
  end

  def weekday(date)
    Date.strptime(date.to_s, '%d.%m.%Y').strftime('%a')
  rescue ArgumentError
    nil
  end

  def quoted(value)
    squished = text(value)
    "«#{squished}»" if squished.present?
  end

  def text(value)
    Captain::EncodingNormalizer.string(value.to_s).squish
  end
end
