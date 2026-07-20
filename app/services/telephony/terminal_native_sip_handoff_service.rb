require 'digest'

class Telephony::TerminalNativeSipHandoffService
  HANDOFF_WINDOW = 2.seconds
  LOCK_RETRIES = 2
  NATIVE_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze
  UNANSWERED_STATUSES = %w[missed no_answer rejected].freeze
  RUNTIME_IDENTITY_KEYS = %w[
    registration_instance_id
    janus_session_id
    janus_handle_id
  ].freeze

  def initialize(call_session:)
    @call_session = call_session
  end

  def perform
    return call_session unless eligible_native_sip_session?(call_session)

    linked = with_handoff_lock { link_handoff!(call_session.reload) }

    linked ? call_session.reload : call_session
  end

  private

  attr_reader :call_session

  def link_handoff!(session)
    current_group = runtime_group(session)
    return false unless unanswered_terminal_group?(current_group)
    return false unless consistent_history_scope?(current_group)

    previous_group = previous_handoff_group(canonical_session(current_group), current_group)
    return false if previous_group.blank?

    history_group_ref = previous_group.filter_map(&:logical_history_group_ref).first.presence ||
                        canonical_session(previous_group).external_call_ref
    persist_history_group!((previous_group + current_group).uniq(&:id), history_group_ref)
    collapse_voice_messages!(previous_group, current_group)
    true
  end

  def eligible_native_sip_session?(session)
    session.direction == 'inbound' &&
      NATIVE_SIP_PROVIDERS.include?(session.provider) &&
      session.answered_at.blank? &&
      UNANSWERED_STATUSES.include?(session.canonical_status)
  end

  def runtime_group(session)
    session.logical_group_sessions.map(&:reload)
  end

  def canonical_session(sessions)
    sessions.min_by do |session|
      root_rank = session.logical_call_group_ref.blank? || session.logical_call_group_ref == session.external_call_ref ? 0 : 1
      [root_rank, session.started_at || session.created_at || Time.zone.at(0), session.id]
    end
  end

  def unanswered_terminal_group?(sessions)
    sessions.present? && sessions.all? do |session|
      session.answered_at.blank? && UNANSWERED_STATUSES.include?(session.canonical_status)
    end
  end

  def previous_handoff_group(current, current_group)
    previous_handoff_candidates(current, current_group).each do |candidate|
      previous_group = runtime_group(candidate)
      next unless eligible_previous_group?(current, previous_group)

      return previous_group
    end

    nil
  end

  def eligible_previous_group?(current, previous_group)
    unanswered_terminal_group?(previous_group) &&
      consistent_history_scope?(previous_group) &&
      previous_group.any? { |session| session.end_reason == 'remote_hangup' } &&
      matching_call_scope?(current, canonical_session(previous_group)) &&
      matching_runtime_identity?(current, canonical_session(previous_group))
  end

  def previous_handoff_candidates(current, current_group)
    return Telephony::CallSession.none if current.created_at.blank?

    scope = Telephony::CallSession.where(
      account_id: current.account_id,
      inbox_id: current.inbox_id,
      number_binding_id: current.number_binding_id,
      conversation_id: current.conversation_id,
      provider: current.provider,
      direction: 'inbound',
      status: UNANSWERED_STATUSES
    )
    scope.where.not(id: current_group.map(&:id))
         .where(answered_at: nil)
         .where(ended_at: (current.created_at - HANDOFF_WINDOW)..current.created_at)
         .order(ended_at: :desc, id: :desc)
  end

  def matching_call_scope?(current, previous)
    current_from = normalized_phone(current.from_number)
    previous_from = normalized_phone(previous.from_number)
    current_to = normalized_phone(current.to_number)
    previous_to = normalized_phone(previous.to_number)

    current_from.present? && current_to.present? &&
      current_from == previous_from && current_to == previous_to
  end

  def normalized_phone(value)
    Contacts::PhoneNumberNormalizer.normalize(value) ||
      Contacts::PhoneNumberNormalizer.normalize(value, default_country: 'KZ') ||
      value.to_s.strip.downcase.presence
  end

  def matching_runtime_identity?(current, previous)
    current_identity = runtime_identity(current)
    previous_identity = runtime_identity(previous)

    current_identity.values.all?(&:present?) && current_identity == previous_identity
  end

  def runtime_identity(session)
    route_metadata = session.metadata.to_h.deep_stringify_keys.fetch('metadata', {})
    {
      'sip_profile_id' => (route_metadata['telephony_sip_profile_id'].presence || route_metadata['target_sip_profile_id'].presence)&.to_s,
      **RUNTIME_IDENTITY_KEYS.index_with { |key| route_metadata[key].presence&.to_s }
    }
  end

  def persist_history_group!(sessions, history_group_ref)
    sessions.sort_by(&:id).each do |session|
      session.with_lock do
        metadata = session.metadata.to_h.deep_dup
        handoff = metadata['history_handoff'].is_a?(Hash) ? metadata['history_handoff'].deep_stringify_keys : {}
        next if handoff['group_ref'] == history_group_ref

        metadata['history_handoff'] = handoff.merge(
          'group_ref' => history_group_ref,
          'reason' => 'rapid_terminal_native_sip_handoff'
        )
        session.update!(metadata: metadata)
      end
    end
  end

  def collapse_voice_messages!(previous_group, current_group)
    current_messages = voice_messages_for(current_group)
    return if current_messages.blank?

    canonical_message = canonical_session(current_group).exact_voice_message || current_messages.first
    duplicate_ids = voice_messages_for(previous_group + current_group).map(&:id) - [canonical_message.id]
    Message.where(
      account_id: call_session.account_id,
      conversation_id: call_session.conversation_id,
      id: duplicate_ids
    ).find_each(&:destroy!)
  end

  def voice_messages_for(sessions)
    return [] unless consistent_history_scope?(sessions)

    source_ids = sessions.filter_map(&:external_call_ref).map { |call_ref| "voice_call:#{call_ref}" }
    Message.where(
      account_id: call_session.account_id,
      inbox_id: call_session.inbox_id,
      conversation_id: call_session.conversation_id
    ).voice_calls.where(source_id: source_ids).order(:created_at, :id).to_a
  end

  def consistent_history_scope?(sessions)
    expected_scope = [call_session.account_id, call_session.inbox_id, call_session.conversation_id]
    sessions.present? && sessions.all? do |session|
      expected_scope == [session.account_id, session.inbox_id, session.conversation_id]
    end
  end

  def with_handoff_lock
    retries = 0
    identity = [
      call_session.account_id,
      call_session.inbox_id,
      call_session.number_binding_id,
      call_session.provider,
      normalized_phone(call_session.from_number),
      normalized_phone(call_session.to_number)
    ].join(':')
    lock_id = Digest::SHA256.digest(identity).unpack1('q>')

    Telephony::CallSession.transaction do
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
      yield
    end
  rescue ActiveRecord::Deadlocked, ActiveRecord::SerializationFailure
    retries += 1
    raise if retries > LOCK_RETRIES

    retry
  end
end
