require 'digest'

class CommunicationThreads::StateTransitionWriter # rubocop:disable Metrics/ClassLength
  FACT_ATTRIBUTES = %w[
    account_id communication_thread_id_snapshot thread_display_id_snapshot contact_id_snapshot event_kind
    occurred_at requested_occurred_at reliable_since source_version from_assignee_id from_assignee_name to_assignee_id to_assignee_name
    from_team_id from_team_name to_team_id to_team_name from_status to_status source source_record_type
    source_record_id source_event_id actor_kind actor_id actor_name idempotency_key request_fingerprint
  ].freeze
  AUTOMATION_ACTOR_TYPES = %w[AssignmentPolicy AutomationRule Inbox].freeze
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def self.with_database_fallback_suppressed(connection)
    connection.select_value("SELECT set_config('onelink.thread_state_fact_writer', '1', true)")
    yield
  ensure
    connection.select_value("SELECT set_config('onelink.thread_state_fact_writer', '', true)")
  end

  # rubocop:disable Metrics/ParameterLists
  def initialize(thread:, attributes:, actor: nil, source: 'conversation', source_record: nil,
                 source_event_id: nil, occurred_at: nil, created: false)
    @thread = thread
    @attributes = attributes.symbolize_keys
    @actor = actor
    @source = source.to_s.presence || 'conversation'
    @source_record = source_record
    @source_event_id = normalize_source_event_id(source_event_id)
    timestamp = occurred_at || Time.current
    @occurred_at = timestamp.change(usec: timestamp.usec)
    @created = created
  end
  # rubocop:enable Metrics/ParameterLists

  def perform # rubocop:disable Metrics/AbcSize
    thread.with_lock do
      existing = CommunicationThreadStateTransitionFact.find_by(account_id: thread.account_id, idempotency_key: idempotency_key)
      return replay_existing!(existing) if existing

      @effective_occurred_at = next_occurred_at
      before = state_snapshot(thread)
      self.class.with_database_fallback_suppressed(thread.class.connection) { thread.update!(attributes) } if attributes.any?
      after = state_snapshot(thread.reload)
      return completed_replay(after) unless created || changed?(before, after)

      payload = fact_payload(before, after)
      persist_fact!(payload)
    end
  end

  private

  attr_reader :thread, :attributes, :actor, :source, :source_record, :source_event_id, :occurred_at, :created

  def replay_existing!(fact) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    actor_identity = actor_snapshot.slice(:actor_kind, :actor_id)
    source_identity = source_record_snapshot(actor_identity[:actor_kind])
    before = { assignee_id: fact.from_assignee_id, team_id: fact.from_team_id, status: fact.from_status }
    after = { assignee_id: fact.to_assignee_id, team_id: fact.to_team_id, status: fact.to_status }
    expected = { account_id: thread.account_id, communication_thread_id_snapshot: thread.id,
                 thread_display_id_snapshot: thread.display_id, contact_id_snapshot: thread.contact_id,
                 event_kind: event_kind(before, after), source_version: 1, source: source,
                 source_event_id: source_event_id, request_fingerprint: request_fingerprint,
                 **actor_identity, **source_identity }
    actual = fact.attributes.symbolize_keys.slice(*expected.keys)
    unless actual == expected && same_instant?(fact.requested_occurred_at, occurred_at) &&
           same_instant?(fact.reliable_since, fact.occurred_at)
      raise ArgumentError, 'idempotency key was already used for another communication thread state transition'
    end

    targets = { assignee_id: fact.to_assignee_id, team_id: fact.to_team_id, status: fact.to_status }
    requested = attributes.slice(*targets.keys)
    current = { assignee_id: thread.assignee_id, team_id: thread.team_id, status: thread.status }
    unless requested.all? { |field, value| targets[field].to_s == value.to_s } && targets == current
      raise ArgumentError, 'stale communication thread state transition replay'
    end

    fact
  end

  def same_instant?(stored, requested)
    stored.to_i == requested.to_i && stored.usec == requested.usec
  end

  def next_occurred_at
    latest = CommunicationThreadStateTransitionFact.where(
      account_id: thread.account_id, communication_thread_id_snapshot: thread.id
    ).order(occurred_at: :desc, id: :desc).pick(:occurred_at)
    return occurred_at unless latest

    [occurred_at, latest + Rational(1, 1_000_000)].max
  end

  def request_fingerprint
    @request_fingerprint ||= Digest::SHA256.hexdigest(JSON.generate(attributes.as_json.sort.to_h))
  end

  def state_snapshot(record)
    {
      assignee_id: record.assignee_id,
      assignee_name: assignee_snapshot_name(record.assignee_id),
      team_id: record.team_id,
      team_name: team_snapshot_name(record.team_id),
      status: record.status
    }
  end

  def assignee_snapshot_name(id)
    return if id.blank?

    membership = AccountUser.includes(:user).find_by(account_id: thread.account_id, user_id: id)
    raise ActiveRecord::RecordNotFound, 'thread state transition assignee belongs to another account' if membership.blank?

    membership.user.name
  end

  def team_snapshot_name(id)
    return if id.blank?

    team = Team.find_by(account_id: thread.account_id, id: id)
    raise ActiveRecord::RecordNotFound, 'thread state transition team belongs to another account' if team.blank?

    team.name
  end

  def changed?(before, after)
    before.values_at(:assignee_id, :team_id, :status) != after.values_at(:assignee_id, :team_id, :status)
  end

  def fact_payload(before, after) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    actor_attributes = actor_snapshot
    record_attributes = source_record_snapshot(actor_attributes[:actor_kind])
    {
      account_id: thread.account_id,
      communication_thread_id_snapshot: thread.id,
      thread_display_id_snapshot: thread.display_id,
      contact_id_snapshot: thread.contact_id,
      event_kind: event_kind(before, after),
      occurred_at: @effective_occurred_at,
      requested_occurred_at: occurred_at,
      reliable_since: @effective_occurred_at,
      source_version: 1,
      from_assignee_id: created ? nil : before[:assignee_id],
      from_assignee_name: created ? nil : before[:assignee_name],
      to_assignee_id: after[:assignee_id],
      to_assignee_name: after[:assignee_name],
      from_team_id: created ? nil : before[:team_id],
      from_team_name: created ? nil : before[:team_name],
      to_team_id: after[:team_id],
      to_team_name: after[:team_name],
      from_status: created ? nil : before[:status],
      to_status: after[:status],
      source: source,
      source_event_id: source_event_id,
      idempotency_key: idempotency_key,
      request_fingerprint: request_fingerprint,
      **record_attributes,
      **actor_attributes
    }
  end

  def event_kind(before, after)
    return 'created' if created
    return 'resolved' if before[:status] != 'resolved' && after[:status] == 'resolved'
    return 'reopened' if before[:status] == 'resolved' && after[:status] != 'resolved'
    return 'routing_changed' if routing_changed?(before, after)

    'state_changed'
  end

  def routing_changed?(before, after)
    before[:assignee_id] != after[:assignee_id] || before[:team_id] != after[:team_id]
  end

  def idempotency_key
    return "thread:#{thread.id}:created:v1" if created

    "thread:#{thread.id}:state:#{source_event_id}:v1"
  end

  def actor_snapshot
    return { actor_kind: 'system', actor_id: nil, actor_name: 'System' } if actor.blank?
    return { actor_kind: 'unknown', actor_id: nil, actor_name: actor.to_s } if actor.is_a?(String)

    actor_type = actor.class.base_class.name
    validate_actor_account!
    kind = actor_kind_for(actor_type)
    actor_id = actor.id unless kind == 'unknown'
    { actor_kind: kind, actor_id: actor_id, actor_name: actor.try(:name).presence || actor_type }
  end

  def actor_kind_for(actor_type)
    return 'user' if actor.is_a?(User)
    return 'contact' if actor.is_a?(Contact)
    return 'captain' if actor.is_a?(Captain::Assistant)
    return 'automation' if AUTOMATION_ACTOR_TYPES.include?(actor_type)

    'unknown'
  end

  def validate_actor_account!
    valid = if actor.is_a?(User)
              AccountUser.exists?(account_id: thread.account_id, user_id: actor.id)
            else
              actor.respond_to?(:account_id) && actor.account_id == thread.account_id
            end
    raise ActiveRecord::RecordNotFound, 'thread state transition actor belongs to another account' unless valid
  end

  def source_record_snapshot(actor_kind)
    record = actor_kind == 'automation' ? actor : source_record
    return { source_record_type: nil, source_record_id: nil } if record.blank?

    if record.respond_to?(:account_id) && record.account_id != thread.account_id
      raise ActiveRecord::RecordNotFound, 'thread state transition source record belongs to another account'
    end

    { source_record_type: record.class.base_class.name, source_record_id: record.id }
  end

  def normalize_source_event_id(value)
    identity = value.to_s.presence || SecureRandom.uuid
    return identity.downcase if identity.match?(UUID_PATTERN)

    digest = Digest::SHA256.hexdigest(identity)
    "#{digest[0, 8]}-#{digest[8, 4]}-5#{digest[13, 3]}-a#{digest[17, 3]}-#{digest[20, 12]}"
  end

  def persist_fact!(payload)
    existing = CommunicationThreadStateTransitionFact.find_by(
      account_id: payload[:account_id], idempotency_key: payload[:idempotency_key]
    )
    return verify_replay!(existing, payload) if existing

    fact = CommunicationThreadStateTransitionFact.create_or_find_by!(
      account_id: payload[:account_id], idempotency_key: payload[:idempotency_key]
    ) do |new_fact|
      new_fact.assign_attributes(payload)
    end
    verify_replay!(fact, payload)
  end

  def completed_replay(after) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    fact = CommunicationThreadStateTransitionFact.find_by(
      account_id: thread.account_id,
      idempotency_key: idempotency_key
    )
    return if fact.blank?

    actor_attributes = actor_snapshot
    source_attributes = source_record_snapshot(actor_attributes[:actor_kind])
    expected = {
      to_assignee_id: after[:assignee_id],
      to_team_id: after[:team_id],
      to_status: after[:status],
      source: source,
      source_event_id: source_event_id,
      request_fingerprint: request_fingerprint,
      requested_occurred_at: occurred_at.to_f.round(6),
      **actor_attributes,
      **source_attributes
    }
    actual = fact.attributes.symbolize_keys.slice(*expected.keys)
                 .merge(requested_occurred_at: fact.requested_occurred_at.to_f.round(6))
    return fact if actual == expected

    conflicting_fields = expected.keys.reject { |key| actual[key] == expected[key] }
    raise ArgumentError,
          "idempotency key was already used for another communication thread state transition (#{conflicting_fields.join(', ')})"
  end

  def verify_replay!(fact, payload)
    expected = payload.stringify_keys.slice(*FACT_ATTRIBUTES)
    actual = fact.attributes.slice(*FACT_ATTRIBUTES)
    return fact if actual == expected

    raise ArgumentError, 'idempotency key was already used for another communication thread state transition'
  end
end
