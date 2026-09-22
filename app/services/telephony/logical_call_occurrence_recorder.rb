require 'digest'
require 'json'

class Telephony::LogicalCallOccurrenceRecorder # rubocop:disable Metrics/ClassLength
  SOURCE_VERSION = 1
  DEFINITION_VERSION = 1
  CONNECTED_STATUSES = %w[in_progress completed].freeze
  OUTBOUND_CONNECTED_EVENT_TYPES = %w[callee_answered customer_answered].freeze
  CONNECTED_FLAG_KEYS = %w[callee_leg_answered calleeLegAnswered target_leg_answered targetLegAnswered].freeze
  ASSISTANT_ID_KEYS = %w[captain_assistant_id captainAssistantId assistant_id assistantId].freeze
  REVISION_IGNORED_FIELDS = %i[created_at reliable_since revision supersedes_occurrence_id].freeze

  def initialize(call_session:, allow_attempted: false, recorded_at: Time.current)
    @call_session = call_session
    @allow_attempted = allow_attempted
    @recorded_at = recorded_at
  end

  def record!
    return unless call_session.persisted? && call_session.started_at.present?

    with_logical_call_lock { record_under_lock! }
  end

  private

  attr_reader :call_session, :allow_attempted, :recorded_at, :existing_attempted

  def record_under_lock!
    sessions = logical_sessions
    @existing_attempted = existing_attempted_occurrence(sessions)
    return if outside_forward_only_boundary?(sessions)

    record_occurrence!('attempted', attempted_source(sessions), sessions) if allow_attempted
    return unless attempted_occurrence_exists?

    connected_source = connected_source(sessions)
    record_occurrence!('connected', connected_source, sessions) if connected_source.present?
    record_occurrence!('terminal', terminal_source(sessions), sessions) if logical_call_terminal?(sessions)
  end

  def with_logical_call_lock
    lock_key = Digest::SHA256.digest(logical_lock_identity).unpack1('q>')
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_key})")
    yield
  end

  def logical_lock_identity
    stable_ref = call_session.canonical_logical_call_key.presence ||
                 call_session.logical_call_group_ref.presence || call_session.external_call_ref
    [call_session.account_id, call_session.provider, call_session.direction, stable_ref].join(':')
  end

  def logical_sessions
    call_session.logical_group_sessions.map(&:reload)
  end

  def canonical_session
    @canonical_session ||= call_session.canonical_logical_call_session.reload
  end

  def logical_call_identity
    @logical_call_identity ||= existing_attempted&.logical_call_identity || begin
      components = [SOURCE_VERSION, call_session.account_id, canonical_session.provider, canonical_session.direction,
                    logical_identity_ref]
      "v#{SOURCE_VERSION}:#{Digest::SHA256.hexdigest(JSON.generate(components))}"
    end
  end

  def logical_call_ref
    @logical_call_ref ||= existing_attempted&.logical_call_ref || canonical_session.external_call_ref
  end

  def logical_identity_ref
    canonical_session.canonical_logical_call_key.presence || canonical_session.external_call_ref
  end

  def existing_attempted_occurrence(sessions)
    Telephony::LogicalCallOccurrence.find_by(
      account_id: call_session.account_id,
      occurrence_kind: 'attempted',
      source_id: sessions.map(&:id)
    )
  end

  def outside_forward_only_boundary?(sessions)
    allow_attempted && existing_attempted.blank? && sessions.any? do |session|
      session.id != call_session.id && session.started_at.present?
    end
  end

  def attempted_occurrence_exists?
    Telephony::LogicalCallOccurrence.exists?(occurrence_identity('attempted'))
  end

  def record_occurrence!(kind, source, sessions)
    return if source.blank?

    attributes = occurrence_attributes(kind, source, sessions)
    return record_revisable_occurrence!(kind, attributes) unless kind == 'attempted'

    identity = occurrence_identity(kind)
    Telephony::LogicalCallOccurrence.create_or_find_by!(identity) do |occurrence|
      occurrence.assign_attributes(attributes.except(*identity.keys).merge(revision: 1))
    end
  end

  def record_revisable_occurrence!(kind, attributes)
    latest = Telephony::LogicalCallOccurrence.where(occurrence_identity(kind)).order(revision: :desc).first
    return latest if latest.present? && revision_attributes_match?(latest, attributes)

    Telephony::LogicalCallOccurrence.create!(
      attributes.merge(
        revision: latest ? latest.revision + 1 : 1,
        supersedes_occurrence_id: latest&.id
      )
    )
  end

  def revision_attributes_match?(occurrence, attributes)
    expected = attributes.except(*REVISION_IGNORED_FIELDS)
    expected.all? { |attribute, value| occurrence.public_send(attribute) == value }
  end

  def occurrence_identity(kind)
    {
      account_id: call_session.account_id,
      logical_call_identity: logical_call_identity,
      occurrence_kind: kind,
      source_version: SOURCE_VERSION
    }
  end

  def occurrence_attributes(kind, source, sessions) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
    connected = connected_source(sessions)
    connected_at = connected&.answered_at
    terminal_at = logical_call_terminal?(sessions) ? terminal_time(sessions) : nil
    actor = occurrence_actor_snapshot(kind, connected)
    duration = terminal_duration(kind, connected_at, terminal_at)

    {
      account_id: call_session.account_id,
      logical_call_identity: logical_call_identity,
      logical_call_ref: logical_call_ref,
      occurrence_kind: kind,
      source_kind: 'telephony_call_session',
      source_id: source.id,
      source_ref: source.external_call_ref,
      correlation_ref: source.provider_call_sid,
      provider: source.provider,
      direction: source.direction,
      **entity_snapshots(source),
      **actor,
      occurred_at: occurred_at(kind, sessions, connected_at, terminal_at),
      connected_at: kind == 'attempted' ? nil : connected_at,
      terminal_at: kind == 'terminal' ? terminal_at : nil,
      duration_seconds: duration,
      duration_source: duration.present? ? 'connected_to_terminal' : nil,
      terminal_status: kind == 'terminal' ? terminal_status(sessions) : nil,
      terminal_reason: kind == 'terminal' ? terminal_reason(sessions) : nil,
      reliability: occurrence_reliability(kind, connected_at),
      reliable_since: recorded_at,
      source_version: SOURCE_VERSION,
      definition_version: DEFINITION_VERSION,
      created_at: recorded_at
    }.compact
  end

  def entity_snapshots(source)
    conversation = account_record(source.conversation)
    {
      inbox_id_snapshot: account_record(source.inbox)&.id,
      contact_id_snapshot: account_record(source.contact)&.id,
      conversation_id_snapshot: conversation&.id,
      communication_thread_id_snapshot: account_record(conversation&.communication_thread)&.id
    }.compact
  end

  def account_record(record)
    record if record.present? && record.account_id == call_session.account_id
  end

  def attempted_source(sessions)
    sessions.min_by { |session| [session.started_at || session.created_at, session.id] }
  end

  def connected_source(sessions)
    sessions.select { |session| connected_evidence?(session) }
            .min_by { |session| [session.answered_at.nil? ? 1 : 0, session.answered_at || Time.zone.at(0), session.id] }
  end

  def terminal_source(sessions)
    sessions.max_by { |session| [session.ended_at || session.last_event_at || session.updated_at, session.id] }
  end

  def connected_evidence?(session)
    return false unless CONNECTED_STATUSES.include?(session.canonical_status)
    return session.answered_at.present? if session.direction == 'inbound'

    outbound_remote_answer_evidence?(session)
  end

  def outbound_remote_answer_evidence?(session)
    return true if explicit_metadata_answer?(session)
    return true if Array.wrap(session.legs).any? { |leg| remote_answered_leg?(leg) }

    webphone_remote_completion_evidence?(session)
  end

  def explicit_metadata_answer?(session)
    metadata_sources(session).any? do |source|
      OUTBOUND_CONNECTED_EVENT_TYPES.include?(source['event_type'].to_s) ||
        OUTBOUND_CONNECTED_EVENT_TYPES.include?(source['event'].to_s) ||
        CONNECTED_FLAG_KEYS.any? { |key| ActiveModel::Type::Boolean.new.cast(source[key]) }
    end
  end

  def webphone_remote_completion_evidence?(session)
    return false unless session.canonical_status == 'completed'

    metadata_sources(session).any? do |source|
      source['webphone_action'].to_s == 'operator_release' &&
        source['release_reason'].to_s == 'remote_hangup' &&
        source['release_status'].to_s == 'completed'
    end
  end

  def remote_answered_leg?(leg)
    return false unless leg.is_a?(Hash)

    leg = leg.deep_stringify_keys
    leg['status'].to_s == 'in_progress' && leg['leg'].to_s != 'operator'
  end

  def logical_call_terminal?(sessions)
    sessions.present? && sessions.all?(&:terminal?)
  end

  def terminal_time(sessions)
    sessions.filter_map { |session| session.ended_at || session.last_event_at }.max || recorded_at
  end

  def occurred_at(kind, sessions, connected_at, terminal_at)
    case kind
    when 'attempted'
      sessions.filter_map { |session| session.started_at || session.created_at }.min
    when 'connected'
      connected_at || terminal_time(sessions)
    when 'terminal'
      terminal_at
    end
  end

  def terminal_duration(kind, connected_at, terminal_at)
    return unless kind == 'terminal' && connected_at.present? && terminal_at.present?

    [terminal_at.to_i - connected_at.to_i, 0].max
  end

  def occurrence_reliability(kind, connected_at)
    kind == 'connected' && connected_at.blank? ? 'unknown' : 'exact'
  end

  def terminal_status(sessions)
    statuses = sessions.map(&:canonical_status).uniq
    statuses.one? ? statuses.first : 'mixed'
  end

  def terminal_reason(sessions)
    reasons = sessions.filter_map(&:end_reason).uniq
    return reasons.first if reasons.one?

    'mixed' if reasons.present?
  end

  def actor_snapshot(source)
    actor_kind, actor_id = actor_identity(source)
    actor = actor_id.present? ? call_session.account.users.find_by(id: actor_id) : nil
    team = explicit_actor_team(source, actor_id)
    assistant = explicit_assistant(source) if actor_kind == 'ai_agent'

    {
      actor_kind: actor_kind,
      actor_id_snapshot: actor&.id,
      actor_name_snapshot: actor&.name,
      actor_team_id_snapshot: team&.id,
      actor_team_name_snapshot: team&.name,
      assistant_id_snapshot: assistant&.id,
      assistant_name_snapshot: assistant&.name
    }.compact
  end

  def occurrence_actor_snapshot(kind, connected_source)
    return actor_snapshot(connected_source) unless kind == 'terminal'

    connected_occurrence = Telephony::LogicalCallOccurrence.current_revision.find_by(occurrence_identity('connected'))
    return actor_snapshot(connected_source) if connected_occurrence.blank?

    connected_occurrence.attributes.symbolize_keys.slice(
      :actor_kind, :actor_id_snapshot, :actor_name_snapshot,
      :actor_team_id_snapshot, :actor_team_name_snapshot,
      :assistant_id_snapshot, :assistant_name_snapshot
    ).compact
  end

  def actor_identity(source)
    return ['unknown', nil] if source.blank?

    value = source.answered_by.to_s.strip
    return ['ai_agent', nil] if value == 'ai_agent'
    return ['system', nil] if value == 'system'

    match = value.match(/\Auser:(\d+)\z/)
    match ? ['human', match[1].to_i] : ['unknown', nil]
  end

  def explicit_actor_team(source, actor_id)
    return if source.blank? || actor_id.blank?

    team_id = metadata_sources(source).filter_map do |metadata|
      metadata['answered_team_id'].presence || metadata['answeredTeamId'].presence
    end.first
    return if team_id.blank?

    Team.joins(:team_members).find_by(account_id: call_session.account_id, id: team_id, team_members: { user_id: actor_id })
  end

  def explicit_assistant(source)
    assistant_id = metadata_sources(source).filter_map do |metadata|
      ASSISTANT_ID_KEYS.filter_map { |key| metadata[key].presence }.first
    end.first
    return if assistant_id.blank?

    Captain::Assistant.find_by(account_id: call_session.account_id, id: assistant_id)
  end

  def metadata_sources(session)
    metadata = session.metadata.to_h.deep_stringify_keys
    sources = [metadata, metadata['metadata'], metadata['last_payload'], metadata.dig('last_payload', 'metadata'),
               metadata['ai_voice'], metadata.dig('ai_voice', 'routing')]
    sources.select { |source| source.is_a?(Hash) }.map(&:deep_stringify_keys)
  end
end
