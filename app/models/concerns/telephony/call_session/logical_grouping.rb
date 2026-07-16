module Telephony::CallSession::LogicalGrouping
  extend ActiveSupport::Concern

  LOGICAL_GROUP_WINDOW = 2.minutes

  def logical_call_key
    route_metadata = logical_metadata_hash('metadata')
    last_payload = logical_metadata_hash('last_payload')

    logical_metadata_value(route_metadata, 'logical_call_key', 'logicalCallKey', 'call_group_key', 'callGroupKey') ||
      logical_metadata_value(last_payload, 'logical_call_key', 'logicalCallKey', 'call_group_key', 'callGroupKey')
  end

  def logical_call_group_ref
    route_metadata = logical_metadata_hash('metadata')
    last_payload = logical_metadata_hash('last_payload')
    nested_payload = last_payload['payload'].is_a?(Hash) ? last_payload['payload'].deep_stringify_keys : {}

    logical_metadata_value(route_metadata, 'logical_call_group_ref', 'bridge_call_ref', 'bridgeCallRef') ||
      logical_metadata_value(last_payload, 'logical_call_group_ref', 'bridge_call_ref', 'bridgeCallRef') ||
      logical_metadata_value(nested_payload, 'logical_call_group_ref', 'bridge_call_ref', 'bridgeCallRef')
  end

  def logical_history_key
    return "session:#{id}" unless direction == 'inbound'

    group_key = logical_call_key.presence || logical_call_group_ref.presence
    return "session:#{id}" if group_key.blank?

    ['logical', provider, inbox_id, group_key].join(':')
  end

  def logical_group_sessions(window: LOGICAL_GROUP_WINDOW)
    candidates = logical_group_candidate_scope(window: window).to_a
    candidates << self unless candidates.any? { |candidate| candidate.id == id }

    selected_ids = [id].compact.to_set
    selected_refs = [external_call_ref].compact_blank.to_set
    selected_keys = [logical_call_key].compact_blank.to_set

    loop do
      related = candidates.select do |candidate|
        selected_ids.include?(candidate.id) ||
          selected_keys.include?(candidate.logical_call_key) ||
          selected_refs.include?(candidate.logical_call_group_ref) ||
          selected_group_refs(candidates, selected_ids).include?(candidate.external_call_ref)
      end
      new_ids = related.filter_map(&:id).to_set
      new_refs = related.filter_map(&:external_call_ref).to_set
      new_keys = related.filter_map(&:logical_call_key).to_set
      break if new_ids.subset?(selected_ids) && new_refs.subset?(selected_refs) && new_keys.subset?(selected_keys)

      selected_ids.merge(new_ids)
      selected_refs.merge(new_refs)
      selected_keys.merge(new_keys)
    end

    candidates.select { |candidate| selected_ids.include?(candidate.id) }
  end

  def canonical_logical_call_session
    sessions = logical_group_sessions
    sessions.min_by do |session|
      root_rank = session.logical_call_group_ref.blank? || session.logical_call_group_ref == session.external_call_ref ? 0 : 1
      [root_rank, session.started_at || session.created_at || Time.zone.at(0), session.id || 0]
    end || self
  end

  def canonical_logical_call_key
    canonical_logical_call_session.logical_call_key.presence || logical_call_key
  end

  private

  def logical_group_candidate_scope(window:)
    reference_time = started_at || created_at || Time.current
    scope = self.class.where(
      account_id: account_id,
      provider: provider,
      direction: direction,
      created_at: (reference_time - window)..(reference_time + window)
    )
    scope = scope.where(inbox_id: inbox_id) if inbox_id.present?
    scope = scope.where(number_binding_id: number_binding_id) if number_binding_id.present?
    scope
  end

  def selected_group_refs(candidates, selected_ids)
    candidates.filter_map do |candidate|
      candidate.logical_call_group_ref if selected_ids.include?(candidate.id)
    end.to_set
  end

  def logical_metadata_hash(key)
    value = metadata.to_h.deep_stringify_keys[key]
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end

  def logical_metadata_value(source, *keys)
    keys.each do |key|
      value = source[key].to_s.strip.presence
      return value if value.present?
    end

    nil
  end
end
