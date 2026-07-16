class Telephony::LogicalCallHistoryQuery
  BATCH_SIZE = 200
  MAX_BATCH_SIZE = 500

  STATUS_PRIORITY = {
    'in_progress' => 0,
    'completed' => 1,
    'connecting' => 2,
    'ringing' => 3,
    'created' => 4,
    'missed' => 5,
    'no_answer' => 5,
    'busy' => 5,
    'cancelled' => 5,
    'rejected' => 5,
    'failed' => 5
  }.freeze

  def initialize(relation:, limit:, status: nil)
    @relation = relation.reorder(nil)
    @limit = limit
    @status = Telephony::CallSession.normalize_status(status) || status.to_s.presence
    @candidate_relation = status.present? ? @relation.where(status: status_values) : @relation
  end

  def call
    groups = scan_groups

    matching_groups(groups)
      .sort_by { |group| group_sort_key(group) }
      .first(limit)
      .map { |group| group.fetch(:representative) }
  end

  private

  attr_reader :candidate_relation, :relation, :limit, :status

  def scan_groups
    sessions_by_id = {}
    cursor = nil
    groups = []

    loop do
      batch = load_batch(cursor)
      break if batch.empty?

      batch.each { |session| sessions_by_id[session.id] = session }
      load_missing_group_parents(sessions_by_id, batch)
      groups = build_groups(sessions_by_id.values)
      break if matching_groups(groups).size >= limit
      break if batch.size < batch_size

      cursor = [batch.last.created_at, batch.last.id]
    end

    groups
  end

  def batch_size
    @batch_size ||= (limit * 4).clamp(BATCH_SIZE, MAX_BATCH_SIZE)
  end

  def load_batch(cursor)
    scope = candidate_relation.order(created_at: :desc, id: :desc)
    if cursor.present?
      created_at, id = cursor
      scope = scope.where('created_at < ? OR (created_at = ? AND id < ?)', created_at, created_at, id)
    end

    scope.limit(batch_size).to_a
  end

  def status_values
    aliases = Telephony::CallSession::STATUS_ALIASES.filter_map do |candidate, canonical|
      candidate if canonical == status
    end
    [status, *aliases]
  end

  def load_missing_group_parents(sessions_by_id, initial_sessions)
    known_refs = sessions_by_id.values.index_by(&:external_call_ref)
    pending_sessions = initial_sessions

    loop do
      parent_refs = missing_parent_refs(pending_sessions, known_refs)
      break if parent_refs.empty?

      parents = relation.where(external_call_ref: parent_refs).to_a
      break if parents.empty?

      store_parent_sessions!(sessions_by_id, known_refs, parents)
      pending_sessions = parents
    end
  end

  def missing_parent_refs(sessions, known_refs)
    sessions.filter_map do |session|
      parent_ref = session.logical_call_group_ref
      parent_ref if missing_parent_ref?(session, parent_ref, known_refs)
    end.uniq
  end

  def missing_parent_ref?(session, parent_ref, known_refs)
    parent_ref.present? && parent_ref != session.external_call_ref && !known_refs.key?(parent_ref)
  end

  def store_parent_sessions!(sessions_by_id, known_refs, parents)
    parents.each do |parent|
      sessions_by_id[parent.id] = parent
      known_refs[parent.external_call_ref] = parent
    end
  end

  def build_groups(sessions)
    disjoint_set = sessions.to_h { |session| [session.id, session.id] }
    union_matching_logical_keys!(disjoint_set, sessions)
    union_parent_chains!(disjoint_set, sessions)

    sessions.group_by { |session| root_id(disjoint_set, session.id) }.values.map do |group_sessions|
      build_group(group_sessions)
    end
  end

  def union_matching_logical_keys!(disjoint_set, sessions)
    sessions_by_logical_key = {}
    sessions.each do |session|
      logical_key = session.logical_history_key
      next unless logical_key.start_with?('logical:')

      existing = sessions_by_logical_key[logical_key]
      existing ? union!(disjoint_set, session.id, existing.id) : sessions_by_logical_key[logical_key] = session
    end
  end

  def union_parent_chains!(disjoint_set, sessions)
    sessions_by_ref = sessions.index_by(&:external_call_ref)
    sessions.each do |session|
      parent = sessions_by_ref[session.logical_call_group_ref]
      union!(disjoint_set, session.id, parent.id) if parent.present? && groupable_together?(session, parent)
    end
  end

  def build_group(sessions)
    {
      representative: sessions.reduce { |current, candidate| preferred_session(current, candidate) },
      newest_created_at: sessions.filter_map(&:created_at).max,
      session_ids: sessions.to_set(&:id)
    }
  end

  def groupable_together?(session, parent)
    session.direction == 'inbound' &&
      parent.direction == 'inbound' &&
      session.provider == parent.provider &&
      session.inbox_id == parent.inbox_id
  end

  def union!(disjoint_set, left_id, right_id)
    left_root = root_id(disjoint_set, left_id)
    right_root = root_id(disjoint_set, right_id)
    disjoint_set[left_root] = right_root unless left_root == right_root
  end

  def root_id(disjoint_set, id)
    parent = disjoint_set.fetch(id)
    return id if parent == id

    disjoint_set[id] = root_id(disjoint_set, parent)
  end

  def preferred_session(current, candidate)
    [current, candidate].min_by { |session| representative_sort_key(session) }
  end

  def representative_sort_key(session)
    [
      session.answered_at.present? ? 0 : 1,
      STATUS_PRIORITY.fetch(session.canonical_status, 6),
      duplicate_branch?(session) ? 1 : 0,
      canonical_group_branch?(session) ? 0 : 1,
      -(session.last_event_at || session.updated_at || session.created_at).to_f,
      -session.id
    ]
  end

  def duplicate_branch?(session)
    session.metadata.to_h.dig('metadata', 'route_reason') == 'duplicate_broadcast_branch'
  end

  def canonical_group_branch?(session)
    group_ref = session.logical_call_group_ref
    group_ref.present? && group_ref == session.external_call_ref
  end

  def matching_groups(groups)
    return groups if status.blank?

    groups.select { |group| group.fetch(:representative).canonical_status == status }
  end

  def group_sort_key(group)
    representative = group.fetch(:representative)
    [
      -group.fetch(:newest_created_at).to_f,
      -representative.id
    ]
  end
end
