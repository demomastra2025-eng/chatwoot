class Captain::ContextSummary
  VERSION = 1
  MAX_ROWS = 12
  DEAL_GROUPS = {
    active: { limit: 8, sort: ['updated_at DESC', 'id DESC'] },
    history: { limit: 4, sort: ['latest(closed_at, archived_at) DESC; created_at fallback when unknown', 'id DESC'] }
  }.freeze
  APPOINTMENT_GROUPS = {
    upcoming: { limit: 6, sort: ['ongoing first', 'starts_at ASC', 'id ASC'] },
    past: { limit: 3, sort: ['ends_at DESC', 'id DESC'] },
    cancelled: { limit: 3, sort: ['planned starts_at DESC', 'id DESC'] }
  }.freeze

  class << self
    def build(kind:, groups:, contact_id:)
      counts = groups.to_h { |group| [group.fetch(:key), group.fetch(:total)] }
      total = counts.values.sum
      shown = groups.sum { |group| group.fetch(:shown) }
      {
        version: VERSION, kind: kind, counts: counts, groups: groups, shown: shown, total: total,
        display: "Показано #{shown} из #{total}",
        scope: { kind: 'current_contact', contact_id: contact_id },
        selection: { mode: 'grouped', max_rows: MAX_ROWS, redistribute: false, current_record: nil },
        sort: groups.to_h { |group| [group.fetch(:key), group.fetch(:sort)] },
        details_tool: kind == 'deals' ? 'get_deal' : 'get_appointment',
        search_tool: kind == 'deals' ? 'search_deals' : 'list_my_appointments'
      }
    end

    def group(key:, total:, items:, config:)
      {
        key: key.to_s, total: total, shown: items.size, display: "Показано #{items.size} из #{total}",
        limit: config.fetch(:limit), sort: config.fetch(:sort), items: items
      }
    end

    # The playground passes synthetic snapshots here. No database or provider access.
    def from_snapshots(kind:, records:, contact_id:, now: Time.current, &serializer)
      records = records.map(&:with_indifferent_access).select do |record|
        record[:contact_id] == contact_id && (kind == 'deals' || (record[:patient_contact_id] || record[:contact_id]) == contact_id)
      end
      configs = kind == 'deals' ? DEAL_GROUPS : APPOINTMENT_GROUPS
      grouped = records.group_by { |record| snapshot_group(kind, record, now) }
      groups = configs.map do |key, config|
        all = grouped.fetch(key, [])
        ordered = all.sort_by { |record| snapshot_sort(kind, key, record, now) }
        items = ordered.first(config[:limit]).map { |record| serializer.call(record) }
        group(key: key, total: all.size, items: items, config: config)
      end
      build(kind: kind, groups: groups, contact_id: contact_id)
    end

    def deal_card(record)
      record = record.with_indifferent_access
      history_at, history_source = deal_history_time(record)
      outcome = record[:outcome] || record[:stage_outcome]
      historical = record[:closed_at].present? || record[:archived_at].present? || (outcome.present? && outcome != 'open')
      {
        id: record[:id], title: record[:title], pipeline_id: record[:pipeline_id], pipeline: record[:pipeline_name],
        stage_id: record[:stage_id], stage: record[:stage_name], outcome: outcome,
        amount: record[:amount], currency: record[:currency], updated_at: record[:updated_at],
        closed_at: record[:closed_at], archived_at: record[:archived_at],
        history_at: historical ? history_at : nil, history_at_source: historical ? history_source : nil
      }.compact
    end

    def deal_history_time(record)
      actual = %i[closed_at archived_at].filter_map { |key| [timestamp(record[key]), key] if record[key].present? }.max_by(&:first)
      return [record[actual.last], actual.last.to_s] if actual

      [record[:created_at], 'created_at_fallback_event_time_unknown']
    end

    private

    def snapshot_group(kind, record, now)
      if kind == 'deals'
        outcome = record[:outcome] || record[:stage_outcome] || 'open'
        return record[:closed_at].present? || record[:archived_at].present? || outcome != 'open' ? :history : :active
      end
      return :cancelled if record[:status] == 'cancelled'

      timestamp(record[:ends_at]) > now.to_f ? :upcoming : :past
    end

    def snapshot_sort(kind, key, record, now)
      id = record[:id].to_i
      return [-timestamp(record[:updated_at] || record[:created_at]), -id] if kind == 'deals' && key == :active
      return [-timestamp(deal_history_time(record).first), -id] if kind == 'deals'
      return [timestamp(record[:starts_at]) <= now.to_f ? 0 : 1, timestamp(record[:starts_at]), id] if key == :upcoming

      [-timestamp(record[key == :past ? :ends_at : :starts_at]), -id]
    end

    def timestamp(value)
      return value.to_f if value.respond_to?(:iso8601) && !value.is_a?(String)
      return 0 if value.blank?

      Time.iso8601(value.to_s).to_f
    end
  end
end
