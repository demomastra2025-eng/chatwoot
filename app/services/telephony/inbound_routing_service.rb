require 'digest'

class Telephony::InboundRoutingService
  DEFAULT_REJECT_MESSAGE = 'We are unable to connect your call right now.'.freeze
  OPERATOR_CANDIDATE_LIMIT = 20
  DUPLICATE_BROADCAST_BRANCH_WINDOW = 5.seconds
  PROVIDER_OWNED_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze

  OperatorCandidate = Struct.new(:source, :agent_binding, :sip_profile, keyword_init: true) do
    def agent_binding_id
      agent_binding&.id
    end

    def sip_profile_id
      sip_profile&.id
    end

    def agent_ref
      return agent_binding.agent_ref if agent_binding

      sip_profile&.agent_ref
    end

    def agent_aor
      agent_binding&.agent_aor || sip_profile&.agent_aor
    end

    def user_id
      agent_binding&.user_id || sip_profile&.user_id
    end

    def user
      agent_binding&.user || sip_profile&.user
    end

    def enabled?
      agent_binding ? agent_binding.enabled? : sip_profile&.enabled?
    end

    def registered_for_routing?
      return agent_binding.registered_for_routing? if agent_binding

      sip_profile&.registered_for_routing?
    end

    def source_name
      source.to_s
    end

    def provider_owned_sip_profile?
      channel_provider = sip_profile&.inbox&.channel&.provider.to_s
      return channel_provider.in?(Telephony::InboundRoutingService::PROVIDER_OWNED_SIP_PROVIDERS) if channel_provider.present?

      sip_profile&.provider_connection&.provider_kind.to_s.in?(Telephony::InboundRoutingService::PROVIDER_OWNED_SIP_PROVIDERS)
    end
  end

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    decision = if number_binding.blank?
                 reject_decision(reason: 'number_not_bound')
               elsif routing_policy.blank?
                 reject_decision(reason: 'routing_policy_missing')
               else
                 routed_decision
               end

    broadcast_fast_incoming_call!(decision)
    enqueue_route_lifecycle!(decision)
    decision
  end

  private

  attr_reader :payload

  def routed_decision
    recursive_runtime_decision = recursive_runtime_call_active_decision
    return recursive_runtime_decision if recursive_runtime_decision.present?

    server_voice_agent_decision = server_voice_agent_runtime_decision
    return server_voice_agent_decision if server_voice_agent_decision.present?

    status_decision = status_aware_conversation_decision
    return status_decision if status_decision.present?

    return out_of_office_decision if inbox&.out_of_office?

    duplicate_broadcast_decision = duplicate_broadcast_branch_decision
    return duplicate_broadcast_decision if duplicate_broadcast_decision.present?

    primary_decision
  end

  def server_voice_agent_runtime_decision
    return unless server_voice_agent_runtime_request?
    return reject_decision(reason: 'voice_agent_sip_profile_missing') unless voice_agent_sip_route_available?
    return ai_decision(reason: 'voice_agent_sip_profile_route') if server_voice_agent_app_ref.present?

    fallback_decision(reason: ai_app_failure_reason, prefer_ai: true)
  end

  def server_voice_agent_runtime_request?
    metadata_value('source').to_s == 'server_janus_sip' ||
      ActiveModel::Type::Boolean.new.cast(payload.dig('janus', 'server_runtime')) ||
      ActiveModel::Type::Boolean.new.cast(metadata_value('server_runtime', 'serverRuntime')) ||
      call_ref.to_s.include?(':janus-server:')
  end

  def out_of_office_decision
    return reject_decision(reason: 'out_of_office', prefer_out_of_office_message: true) if routing_policy.operator_mode?

    fallback_decision(reason: 'out_of_office', prefer_out_of_office_message: true)
  end

  def primary_decision
    case routing_policy.mode
    when 'operator'
      return target_operator_decision(reason: 'operator_route') if target_operator_requested?
      return operator_decision(reason: 'operator_route') if operator_routable?

      reject_decision(reason: 'operator_unavailable')
    when 'app'
      return app_decision(reason: 'app_route') if resolved_primary_app_ref.present?

      fallback_decision(reason: primary_app_failure_reason)
    when 'ai'
      return reject_decision(reason: 'voice_agent_sip_profile_missing') unless voice_agent_sip_route_available?
      return ai_decision(reason: 'ai_route') if resolved_ai_app_ref.present?

      fallback_decision(reason: ai_app_failure_reason)
    when 'reject'
      reject_decision(reason: 'reject_route')
    else
      fallback_decision(reason: 'unsupported_mode')
    end
  end

  def status_aware_conversation_decision
    return unless status_aware_ai_route_enabled?
    return if existing_voice_conversation.blank?

    return pending_conversation_ai_decision if existing_voice_conversation.pending?
  end

  def status_aware_ai_route_enabled?
    return true if routing_policy.ai_mode?

    routing_policy.ai_enabled? && routing_policy.captain_assistant.present?
  end

  def pending_conversation_ai_decision
    return reject_decision(reason: 'voice_agent_sip_profile_missing') unless voice_agent_sip_route_available?
    return ai_decision(reason: 'pending_conversation_ai_route') if resolved_ai_app_ref.present?

    fallback_decision(reason: ai_app_failure_reason)
  end

  def enqueue_route_lifecycle!(decision)
    return if number_binding.blank?
    return if call_ref.blank? || caller_number.blank?
    return if diagnostic_route_probe?

    Telephony::InboundRouteLifecycleJob.perform_later(route_lifecycle_payload(decision))
  rescue StandardError => e
    Rails.logger.error(
      'TELEPHONY_INBOUND_ROUTE_LIFECYCLE_ENQUEUE_FAILED ' \
      "call_ref=#{call_ref} account_id=#{number_binding&.account_id} error=#{e.class.name}: #{e.message}"
    )
  end

  def broadcast_fast_incoming_call!(decision)
    return unless operator_decision?(decision)
    return if number_binding.blank?
    return if call_ref.blank? || caller_number.blank?
    return if diagnostic_route_probe?
    return if sipuni_pre_operator_leg?

    call_session, should_broadcast = ensure_fast_incoming_call_session!(decision)
    return if call_session.blank? || call_session.terminal? || !should_broadcast

    targets = fast_incoming_call_pubsub_targets
    return if targets.blank?

    targets.each do |target|
      ActionCable.server.broadcast(
        target[:token],
        {
          event: 'voice_call.incoming',
          data: fast_incoming_call_payload(decision, candidate: target[:candidate])
        }
      )
    end
  rescue StandardError => e
    Rails.logger.warn(
      'TELEPHONY_FAST_INCOMING_BROADCAST_FAILED ' \
      "call_ref=#{call_ref} account_id=#{number_binding&.account_id} error=#{e.class.name}: #{e.message}"
    )
  end

  def fast_incoming_call_pubsub_targets
    operator_candidates.filter_map do |candidate|
      token = candidate.user&.pubsub_token
      { token: token, candidate: candidate } if token.present?
    end.uniq { |target| target[:token] }
  end

  def ensure_fast_incoming_call_session!(decision)
    call_session = find_or_create_fast_incoming_call_session!
    should_broadcast = false

    call_session.with_lock do
      call_session.reload
      unless call_session.terminal?
        should_broadcast = !fast_incoming_broadcast_sent?(call_session)
        call_session.assign_attributes(fast_incoming_call_session_attributes(decision, call_session))
        call_session.save! if call_session.changed?
      end
    end

    [call_session, should_broadcast]
  end

  def fast_incoming_broadcast_sent?(call_session)
    metadata = (call_session.metadata || {}).deep_stringify_keys
    metadata.dig('fast_incoming_broadcast', 'event_key') == route_lifecycle_event_key
  end

  def find_or_create_fast_incoming_call_session!
    number_binding.account.telephony_call_sessions.find_or_create_by!(external_call_ref: call_ref) do |session|
      session.assign_attributes(
        provider: number_binding.provider.presence,
        status: 'ringing',
        direction: 'inbound',
        started_at: Time.current,
        last_event_at: Time.current,
        legs: [],
        metadata: {}
      )
    end
  rescue ActiveRecord::RecordInvalid => e
    raise unless e.record&.errors&.of_kind?(:external_call_ref, :taken)

    number_binding.account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  end

  def fast_incoming_call_session_attributes(decision, call_session)
    {
      account: number_binding.account,
      conversation: existing_voice_conversation || call_session.conversation,
      contact: existing_voice_conversation&.contact || call_session.contact,
      inbox: inbox || call_session.inbox,
      number_binding: number_binding,
      provider: number_binding.provider.presence || call_session.provider,
      status: call_session.status.presence || 'ringing',
      direction: 'inbound',
      from_number: caller_number,
      to_number: inbound_number || number_binding.phone_number,
      started_at: call_session.started_at || Time.current,
      last_event_at: [call_session.last_event_at, Time.current].compact.max,
      metadata: fast_incoming_call_session_metadata(decision, call_session)
    }.compact
  end

  def fast_incoming_call_session_metadata(decision, call_session)
    metadata = (call_session.metadata || {}).deep_dup.deep_stringify_keys
    existing_route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'].deep_dup : {}
    metadata['metadata'] = existing_route_metadata.deep_merge(
      route_lifecycle_metadata(decision).deep_stringify_keys
    )
    metadata['fast_incoming_broadcast'] = {
      'event' => 'voice_call.incoming',
      'event_key' => route_lifecycle_event_key,
      'created_at' => Time.current.iso8601
    }
    metadata.compact
  end

  def fast_incoming_call_payload(decision, candidate: nil)
    conversation = existing_voice_conversation
    contact = conversation&.contact
    route_metadata = route_lifecycle_metadata(decision)
    sip_profile_id = candidate&.sip_profile_id ||
                     primary_operator_candidate&.sip_profile_id ||
                     route_metadata[:target_sip_profile_id] ||
                     route_metadata[:telephony_sip_profile_id]
    route_sip_profile_id = route_metadata[:target_sip_profile_id] || route_metadata[:telephony_sip_profile_id]
    candidate_owns_janus_branch = candidate.blank? ||
                                  candidate.sip_profile_id.blank? ||
                                  route_sip_profile_id.blank? ||
                                  candidate.sip_profile_id.to_s == route_sip_profile_id.to_s
    janus_call_ref = route_metadata[:janus_call_ref] if candidate_owns_janus_branch
    janus_session_key = if candidate&.sip_profile_id.present?
                          "sip_profile:#{candidate.sip_profile_id}"
                        elsif candidate_owns_janus_branch
                          route_metadata[:janus_session_key]
                        end

    {
      account_id: number_binding.account_id,
      inbox_id: number_binding.inbox_id,
      number_ref: number_binding.number_ref,
      provider: number_binding.provider,
      call_sid: call_ref,
      callSid: call_ref,
      call_ref: call_ref,
      logical_call_key: logical_call_key,
      logicalCallKey: logical_call_key,
      call_group_key: logical_call_key,
      callGroupKey: logical_call_key,
      status: 'ringing',
      operator_distribution_mode: operator_distribution_mode,
      call_direction: 'inbound',
      direction: 'inbound',
      conversation_id: conversation&.display_id,
      conversation_display_id: conversation&.display_id,
      conversation_db_id: conversation&.id,
      contact_id: contact&.id,
      sender_id: contact&.id,
      from_number: caller_number,
      to_number: inbound_number || number_binding.phone_number,
      caller: fast_incoming_call_caller_payload(contact),
      operator_pool: decision[:operator_pool] || decision['operator_pool'],
      operator_pool_size: decision[:operator_pool_size] || decision['operator_pool_size'],
      operator_candidates: decision[:operator_candidates] || decision['operator_candidates'],
      operator_internal_extension: candidate&.sip_profile&.internal_extension ||
        primary_operator_candidate&.sip_profile&.internal_extension,
      sip_profile_id: sip_profile_id,
      sipProfileId: sip_profile_id,
      janus_call_ref: janus_call_ref,
      janusCallRef: janus_call_ref,
      janus_session_key: janus_session_key,
      janusSessionKey: janus_session_key,
      sipuni_native_webphone_correlation: route_metadata[:sipuni_native_webphone_correlation],
      sipuniNativeWebphoneCorrelation: route_metadata[:sipuni_native_webphone_correlation],
      browser_join_supported: route_metadata[:browser_join_supported],
      browserJoinSupported: route_metadata[:browser_join_supported],
      created_at: Time.current.to_i
    }.compact
  end

  def fast_incoming_call_caller_payload(contact)
    {
      id: contact&.id,
      name: contact&.name,
      phone_number: contact&.phone_number || caller_number
    }.compact
  end

  def route_lifecycle_payload(decision)
    {
      event_key: route_lifecycle_event_key,
      event: 'session_started',
      call_ref: call_ref,
      account_id: number_binding.account_id,
      inbox_id: number_binding.inbox_id,
      number_ref: number_binding.number_ref,
      provider: number_binding.provider,
      direction: 'inbound',
      ingress_number: inbound_number || number_binding.phone_number,
      caller_number: caller_number,
      metadata: route_lifecycle_metadata(decision)
    }.compact
  end

  def route_lifecycle_metadata(decision)
    metadata = {
      route_action: decision[:action] || decision['action'],
      route_reason: decision[:reason] || decision['reason'],
      chatwoot_account_id: number_binding.account_id,
      chatwoot_inbox_id: number_binding.inbox_id,
      number_ref: number_binding.number_ref,
      operator_distribution_mode: operator_distribution_mode,
      logical_call_key: logical_call_key,
      call_group_key: logical_call_key,
      logical_call_group_ref: logical_call_group_ref
    }
    metadata.merge!(sipuni_leg_metadata)
    metadata.merge!(browser_sip_route_metadata)

    metadata.merge!(target_route_metadata) if target_operator_requested?
    metadata.merge!(operator_route_metadata(decision)) if operator_decision?(decision)

    if existing_voice_conversation.present?
      metadata[:chatwoot_conversation_id] = existing_voice_conversation.id
      metadata[:chatwoot_conversation_status] = existing_voice_conversation.status
    end

    metadata.compact
  end

  def target_route_metadata
    {
      target_extension: target_operator_extension,
      target_operator_agent_aor: target_operator_aor,
      target_sip_profile_id: target_operator_candidate&.sip_profile_id,
      target_user_id: target_operator_candidate&.user_id
    }.compact
  end

  def browser_sip_route_metadata
    metadata = {
      janus_call_ref: metadata_value('janus_call_ref', 'janusCallRef'),
      janus_session_key: metadata_value('janus_session_key', 'janusSessionKey'),
      telephony_sip_profile_id: metadata_value(
        'telephony_sip_profile_id',
        'telephonySipProfileId'
      ),
      target_sip_profile_id: metadata_value(
        'target_sip_profile_id',
        'targetSipProfileId'
      ),
      target_user_id: metadata_value('target_user_id', 'targetUserId'),
      target_extension: metadata_value('target_extension', 'targetExtension'),
      operator_internal_extension: metadata_value(
        'operator_internal_extension',
        'operatorInternalExtension'
      )
    }.compact

    if raw_metadata_key?('browser_join_supported', 'browserJoinSupported')
      metadata[:browser_join_supported] =
        ActiveModel::Type::Boolean.new.cast(
          raw_metadata_value('browser_join_supported', 'browserJoinSupported')
        )
    end

    if raw_metadata_key?('sipuni_native_webphone_correlation', 'sipuniNativeWebphoneCorrelation')
      metadata[:sipuni_native_webphone_correlation] =
        ActiveModel::Type::Boolean.new.cast(
          raw_metadata_value(
            'sipuni_native_webphone_correlation',
            'sipuniNativeWebphoneCorrelation'
          )
        )
    end

    metadata
  end

  def operator_route_metadata(decision)
    candidates = decision[:operator_candidates] || decision['operator_candidates'] || []
    return {} if candidates.blank?

    candidate_hashes = candidates.map(&:deep_stringify_keys)
    {
      operator_pool: true,
      operator_pool_size: candidate_hashes.size,
      operator_candidates: candidate_hashes,
      operator_candidate_binding_ids: candidate_hashes.filter_map { |candidate| candidate['agent_binding_id'] || candidate['id'] },
      operator_candidate_sip_profile_ids: candidate_hashes.filter_map { |candidate| candidate['sip_profile_id'] },
      operator_candidate_user_ids: candidate_hashes.filter_map { |candidate| candidate['user_id'] },
      operator_candidate_agent_refs: candidate_hashes.filter_map { |candidate| candidate['agent_ref'] },
      operator_candidate_agent_aors: candidate_hashes.filter_map { |candidate| candidate['agent_aor'] },
      operator_candidate_sources: candidate_hashes.filter_map { |candidate| candidate['source'] }
    }.compact
  end

  def operator_decision?(decision)
    (decision[:action] || decision['action']).to_s == 'operator'
  end

  def diagnostic_route_probe?
    truthy_payload?('diagnostic', 'diagnostic_call', 'test', 'test_call')
  end

  def truthy_payload?(*keys)
    keys.any? do |key|
      value = payload_value(key, key.to_s.camelize(:lower))
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end

  def route_lifecycle_event_key
    "route_lookup:#{call_ref}:session_started"
  end

  def logical_call_key
    @logical_call_key ||= begin
      explicit_key = explicit_logical_call_key
      if explicit_key.present?
        explicit_key
      else
        digest = Digest::SHA256.hexdigest(logical_call_key_parts.join('|'))[0, 32]
        "janus-inbound:#{digest}"
      end
    end
  end

  def explicit_logical_call_key
    value = payload_value('logical_call_key', 'logicalCallKey', 'call_group_key', 'callGroupKey') ||
            metadata_value('logical_call_key', 'logicalCallKey', 'call_group_key', 'callGroupKey')
    value.to_s.strip.presence
  end

  def logical_call_key_parts
    [
      'v2',
      number_binding.account_id,
      number_binding.inbox_id,
      number_binding.id,
      number_binding.number_ref,
      normalize_logical_call_value(logical_call_group_ref),
      normalize_logical_call_value(caller_number),
      normalize_logical_call_value(inbound_number || number_binding.phone_number)
    ]
  end

  def logical_call_group_ref
    @logical_call_group_ref ||= begin
      explicit_ref = payload_value(
        'bridge_call_ref', 'bridgeCallRef',
        'parent_call_ref', 'parentCallRef',
        'root_call_ref', 'rootCallRef',
        'original_call_ref', 'originalCallRef',
        'linked_id', 'linkedId', 'linkedid'
      ) || metadata_value(
        'bridge_call_ref', 'bridgeCallRef',
        'parent_call_ref', 'parentCallRef',
        'root_call_ref', 'rootCallRef',
        'original_call_ref', 'originalCallRef',
        'linked_id', 'linkedId', 'linkedid'
      )
      explicit_ref = explicit_ref.to_s.strip.presence
      if useful_explicit_logical_group_ref?(explicit_ref)
        explicit_ref
      else
        logical_bridge_call_ref_for_context.presence || call_ref
      end
    end
  end

  def useful_explicit_logical_group_ref?(value)
    value.present? && value != call_ref
  end

  def normalize_logical_call_value(value)
    value.to_s.strip.downcase
  end

  def fallback_decision(reason:, prefer_out_of_office_message: false, prefer_ai: false)
    fallback_order(prefer_ai: prefer_ai).each do |mode|
      case mode
      when 'operator'
        return target_operator_decision(reason: reason) if target_operator_requested?
        return operator_decision(reason: reason) if operator_routable?
      when 'ai'
        next unless voice_agent_sip_route_available?

        return ai_decision(reason: reason) if resolved_ai_app_ref.present?
      when 'app'
        return app_decision(reason: reason) if resolved_primary_app_ref.present?
      end
    end

    reject_decision(reason: reason, prefer_out_of_office_message: prefer_out_of_office_message)
  end

  def fallback_order(prefer_ai: false)
    order = case routing_policy.fallback_mode
            when 'operator'
              %w[operator app]
            when 'app'
              %w[app operator]
            when 'ai'
              %w[ai operator app]
            else
              []
            end

    return order unless prefer_ai && fallback_target_available?('ai')

    (['ai'] + order).uniq
  end

  def operator_routable?
    operator_candidates.any?
  end

  def target_operator_decision(reason:)
    block_reason = target_operator_block_reason
    return reject_decision(reason: block_reason) if block_reason.present?

    operator_decision(reason: reason)
  end

  def target_operator_requested?
    targeted_operator_distribution? && (target_operator_extension.present? || target_operator_aor.present?)
  end

  def target_operator_block_reason
    return unless target_operator_requested?
    return 'target_operator_not_found' if target_operator_candidate.blank?
    return 'target_operator_unavailable' unless target_operator_candidate.enabled? &&
                                                sip_operator_aor?(target_operator_candidate.agent_aor) &&
                                                target_operator_candidate.registered_for_routing?
    return 'target_operator_busy' if target_operator_busy?(target_operator_candidate)
  end

  def target_operator_busy?(candidate)
    without_busy_operator_candidates([candidate]).blank?
  end

  def duplicate_broadcast_branch_decision
    return unless routing_policy&.operator_mode?
    return if targeted_operator_distribution?
    return if diagnostic_route_probe?
    return unless broadcast_operator_branch_target_metadata?
    return if broadcast_duplicate_call_session.blank?

    reject_decision(reason: 'duplicate_broadcast_branch', include_bridge_context: true)
  end

  def broadcast_operator_branch_target_metadata?
    target_operator_extension.present? || target_operator_aor.present?
  end

  def broadcast_duplicate_call_session
    @broadcast_duplicate_call_session ||= recent_logical_bridge_call_session_scope
                                          .where.not(status: Telephony::CallSession::TERMINAL_STATUSES)
                                          .where('created_at >= ?', DUPLICATE_BROADCAST_BRANCH_WINDOW.ago)
                                          .order(created_at: :desc, id: :desc)
                                          .first
  end

  def resolved_operator_aor
    primary_operator_candidate&.agent_aor.presence || routing_policy.operator_agent_aor
  end

  def sip_operator_aor?(value)
    value.to_s.downcase.start_with?('sip:')
  end

  def operator_decision(reason:)
    {
      action: 'operator',
      reason: reason
    }.merge(operator_target_payload).merge(shared_context)
  end

  def operator_target_payload
    candidates = operator_candidates
    primary = candidates.first
    return {} if primary.blank?

    candidate_payload = candidates.map { |candidate| operator_candidate_payload(candidate) }
    {
      agent_aor: primary.agent_aor,
      agent_ref: primary.agent_ref,
      agent_aors: candidate_payload.filter_map { |candidate| candidate[:agent_aor] },
      operator_pool: candidate_payload.size > 1,
      operator_pool_size: candidate_payload.size,
      operator_candidates: candidate_payload
    }.compact
  end

  def target_operator_candidate
    @target_operator_candidate ||= inbox_sip_profile_candidates.find do |candidate|
      target_operator_candidate_matches?(candidate)
    end
  end

  def target_operator_candidate_matches?(candidate)
    profile = candidate.sip_profile
    return false if profile.blank?

    extension_matches = target_operator_extension.blank? || profile.internal_extension.to_s == target_operator_extension
    aor_matches = target_operator_aor.blank? || normalized_sip_aor(profile.agent_aor) == normalized_sip_aor(target_operator_aor)
    extension_matches && aor_matches
  end

  def target_operator_extension
    @target_operator_extension ||= begin
      value = payload_value('target_extension', 'targetExtension') ||
              metadata_value('target_extension', 'targetExtension')
      value.to_s.strip.presence
    end
  end

  def target_operator_aor
    @target_operator_aor ||= begin
      value = payload_value('target_operator_agent_aor', 'targetOperatorAgentAor', 'operator_agent_aor', 'operatorAgentAor') ||
              metadata_value('target_operator_agent_aor', 'targetOperatorAgentAor', 'operator_agent_aor', 'operatorAgentAor')
      value.to_s.strip.presence
    end
  end

  def normalized_sip_aor(value)
    value.to_s.strip.downcase.presence
  end

  def operator_candidates
    @operator_candidates ||= if target_operator_requested?
                               target_operator_block_reason.present? ? [] : [target_operator_candidate]
                             else
                               scoped_candidates = operator_candidate_scope.select do |candidate|
                                 candidate.enabled? && sip_operator_aor?(candidate.agent_aor)
                               end
                               candidates = available_operator_candidates(scoped_candidates)
                               candidates.sort_by { |candidate| operator_candidate_sort_key(candidate) }.first(OPERATOR_CANDIDATE_LIMIT)
                             end
  end

  def available_operator_candidates(candidates)
    without_busy_operator_candidates(candidates.select(&:registered_for_routing?))
  end

  def without_busy_operator_candidates(candidates)
    busy_binding_ids = busy_operator_binding_ids(candidates.filter_map(&:agent_binding_id))
    busy_sip_profile_ids = busy_operator_sip_profile_ids(candidates.filter_map(&:sip_profile_id))

    candidates.reject do |candidate|
      busy_binding_ids.include?(candidate.agent_binding_id) ||
        busy_sip_profile_ids.include?(candidate.sip_profile_id)
    end
  end

  def primary_operator_candidate
    operator_candidates.first
  end

  def operator_candidate_scope
    inbox_sip_profile_candidates
  end

  def inbox_sip_profile_candidates
    return [] if inbox.blank? || !inbox.respond_to?(:telephony_sip_profiles)

    scope = inbox.telephony_sip_profiles.human_operator.includes(:user)
    scope = scope.where(user_id: inbox.members.select(:id)) if inbox.inbox_members.exists?
    return [] unless scope.exists?

    scope.map { |profile| OperatorCandidate.new(source: :sip_profile, sip_profile: profile) }
  end

  def busy_operator_binding_ids(candidate_ids)
    return [] if candidate_ids.blank?

    Telephony::CallSession.active
                          .where(account_id: number_binding.account_id, agent_binding_id: candidate_ids)
                          .where.not(external_call_ref: call_ref)
                          .distinct
                          .pluck(:agent_binding_id)
  end

  def busy_operator_sip_profile_ids(candidate_ids)
    candidate_ids = candidate_ids.filter_map { |value| value.presence&.to_i }.uniq
    return [] if candidate_ids.blank?

    Telephony::CallSession.active
                          .where(account_id: number_binding.account_id)
                          .where.not(external_call_ref: call_ref)
                          .pluck(:metadata)
                          .filter_map { |metadata| metadata.to_h.dig('operator_claim', 'sip_profile_id').presence&.to_i }
                          .select { |sip_profile_id| candidate_ids.include?(sip_profile_id) }
                          .uniq
  end

  def operator_candidate_sort_key(candidate)
    preferred = operator_candidate_configured?(candidate) ? 0 : 1
    [
      preferred,
      candidate.user_id || 0,
      candidate.agent_ref.to_s,
      candidate.sip_profile_id || candidate.agent_binding_id || 0
    ]
  end

  def operator_candidate_configured?(candidate)
    return candidate.agent_ref.to_s == routing_policy.operator_agent_ref.to_s if routing_policy.operator_agent_ref.present?
    return candidate.agent_aor.to_s == routing_policy.operator_agent_aor.to_s if routing_policy.operator_agent_aor.present?

    false
  end

  def operator_candidate_payload(candidate)
    {
      id: candidate.agent_binding_id,
      source: candidate.source_name,
      agent_binding_id: candidate.agent_binding_id,
      sip_profile_id: candidate.sip_profile_id,
      agent_ref: candidate.agent_ref,
      agent_aor: candidate.agent_aor,
      user_id: candidate.user_id,
      name: candidate.user&.name,
      internal_extension: candidate.sip_profile&.internal_extension,
      availability_mode: candidate.sip_profile&.availability_mode
    }.compact
  end

  def fallback_target_available?(mode)
    case mode
    when 'ai'
      resolved_ai_app_ref.present?
    when 'app'
      resolved_primary_app_ref.present?
    else
      false
    end
  end

  def app_decision(reason:)
    {
      action: 'app',
      app_ref: resolved_primary_app_ref,
      reason: reason
    }.merge(shared_context(include_bridge_context: true))
  end

  def ai_decision(reason:)
    decision = {
      action: 'ai',
      ai_mode: routing_policy.ai_deployment_mode,
      app_ref: resolved_ai_app_ref,
      reason: reason
    }.merge(shared_context(include_bridge_context: true))

    attach_ai_context(decision)
  end

  def reject_decision(reason:, prefer_out_of_office_message: false, include_bridge_context: false)
    {
      action: 'reject',
      message: reject_message(prefer_out_of_office_message: prefer_out_of_office_message),
      reason: reason
    }.merge(shared_context(include_bridge_context: include_bridge_context))
  end

  def attach_ai_context(decision)
    return decision if existing_voice_conversation.blank?

    decision.merge(ai_context: ai_context_payload(decision))
  rescue StandardError => e
    Rails.logger.warn(
      'TELEPHONY_INBOUND_ROUTE_AI_CONTEXT_FAILED ' \
      "call_ref=#{call_ref} account_id=#{number_binding&.account_id} error=#{e.class.name}: #{e.message}"
    )
    decision
  end

  def voice_agent_sip_route_available?
    return true unless janus_sip_route?

    voice_agent_sip_profile.present?
  end

  def ai_context_payload(decision)
    Telephony::AiVoice::ContextBuilder.new(
      params: {
        call_ref: call_ref,
        prefer_exact_call_ref: server_voice_agent_runtime_request?,
        account_id: decision[:account_id],
        number_ref: decision[:number_ref],
        ingress_number: inbound_number || number_binding&.phone_number,
        caller_number: caller_number,
        bridge_call_ref: decision[:bridge_call_ref],
        conversation_id: decision[:conversation_id],
        provider: number_binding&.provider,
        direction: 'inbound',
        transport: 'janus_sip'
      }.compact
    ).perform
  end

  def reject_message(prefer_out_of_office_message: false)
    return inbox.out_of_office_message if prefer_out_of_office_message && inbox&.out_of_office_message.present?
    return routing_policy.fallback_message if routing_policy&.fallback_message.present?
    return inbox.out_of_office_message if inbox&.out_of_office_message.present?

    DEFAULT_REJECT_MESSAGE
  end

  def recursive_runtime_call_active_decision
    return unless direct_onelink_ai_runtime_request?
    return if server_voice_agent_runtime_request?
    return if existing_voice_conversation.blank?
    return if active_bridge_call_ref_for_context.blank?

    reject_decision(reason: 'recursive_runtime_call_active', include_bridge_context: true)
  end

  def shared_context(include_bridge_context: false)
    return {} if number_binding.blank?

    context = {
      account_id: number_binding.account_id,
      inbox_id: number_binding.inbox_id,
      number_ref: number_binding.number_ref,
      logical_call_key: logical_call_key,
      call_group_key: logical_call_key,
      logical_call_group_ref: logical_call_group_ref,
      voice_agent_sip_profile_id: voice_agent_sip_profile&.id,
      operator_distribution_mode: operator_distribution_mode,
      recording: recording_payload
    }

    return context.compact unless include_bridge_context

    context[:bridge_call_ref] = route_bridge_call_ref_for_context

    if existing_voice_conversation.present?
      context[:conversation_id] = existing_voice_conversation.id
      context[:conversation_display_id] = existing_voice_conversation.display_id
      context[:conversation_status] = existing_voice_conversation.status
    end

    context.compact
  end

  def recording_payload
    {
      enabled: recording_enabled?,
      source: 'onelink_runtime',
      storage_provider: 'onelink_storage'
    }
  end

  def recording_enabled?
    settings = (routing_policy&.ai_voice_settings || {}).deep_stringify_keys
    return ActiveModel::Type::Boolean.new.cast(settings['recording_enabled']) if settings.key?('recording_enabled')

    true
  end

  def routing_policy
    @routing_policy ||= number_binding&.routing_policy
  end

  def operator_distribution_mode
    @operator_distribution_mode ||= routing_policy&.operator_distribution_mode ||
                                    Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_BROADCAST
  end

  def targeted_operator_distribution?
    operator_distribution_mode == Telephony::RoutingPolicy::OPERATOR_DISTRIBUTION_TARGETED
  end

  def resolved_primary_app_ref
    @resolved_primary_app_ref ||= routable_app_ref(number_binding&.configured_app_ref)
  end

  def resolved_ai_app_ref
    @resolved_ai_app_ref ||= if server_voice_agent_runtime_request?
                               server_voice_agent_app_ref
                             elsif direct_onelink_ai_runtime_request?
                               routing_policy.effective_ai_app_ref
                             else
                               routable_app_ref(routing_policy&.effective_ai_app_ref)
                             end
  end

  def server_voice_agent_app_ref
    @server_voice_agent_app_ref ||= routing_policy&.effective_ai_app_ref.presence || runtime_app_ref
  end

  def direct_onelink_ai_runtime_request?
    return false if runtime_app_ref.blank?
    return false unless routing_policy&.ai_deployment_mode == Telephony::RoutingPolicy::AI_DEPLOYMENT_ONELINK_MANAGED

    runtime_app_ref == routing_policy.effective_ai_app_ref
  end

  def primary_app_failure_reason
    number_binding&.configured_app_ref.present? ? 'recursive_runtime_app_ref' : 'app_ref_missing'
  end

  def ai_app_failure_reason
    return 'ai_app_ref_missing' if server_voice_agent_runtime_request? && server_voice_agent_app_ref.blank?

    routing_policy&.effective_ai_app_ref.present? ? 'recursive_runtime_app_ref' : 'ai_app_ref_missing'
  end

  def routable_app_ref(candidate_app_ref)
    return if candidate_app_ref.blank?
    return if runtime_app_ref.present? && candidate_app_ref == runtime_app_ref

    candidate_app_ref
  end

  def runtime_app_ref
    payload_value('app_ref', 'appRef')
  end

  def inbox
    @inbox ||= number_binding&.inbox
  end

  def janus_sip_route?
    transport = payload_value('transport') || metadata_value('transport')
    return true if transport.to_s == 'janus_sip'
    return true if metadata_value('janus_call_ref', 'janusCallRef').present?

    call_ref.to_s.include?(':janus:') || call_ref.to_s.include?(':janus-server:')
  end

  def voice_agent_sip_profile
    @voice_agent_sip_profile ||= begin
      profile_id = metadata_value('voice_agent_sip_profile_id', 'voiceAgentSipProfileId', 'target_sip_profile_id', 'targetSipProfileId')
      scope = number_binding&.inbox&.telephony_sip_profiles&.voice_agent&.enabled
      scope = scope&.where&.not(status: %w[disabled deleting failed])
      if profile_id.present?
        scope&.find_by(id: profile_id)
      else
        scope&.recent&.first
      end
    end
  end

  def existing_voice_conversation
    @existing_voice_conversation ||= conversation_from_call_ref || conversation_from_caller_number
  end

  def bridge_call_ref_for_context
    return if existing_voice_conversation.blank?

    @bridge_call_ref_for_context ||= active_bridge_call_ref_for_context ||
                                     recent_bridge_call_session_scope.order(created_at: :desc, id: :desc).pick(:external_call_ref)
  end

  def route_bridge_call_ref_for_context
    return call_ref if server_voice_agent_runtime_request?

    bridge_call_ref_for_context
  end

  def active_bridge_call_ref_for_context
    return if existing_voice_conversation.blank?

    @active_bridge_call_ref_for_context ||= recent_bridge_call_session_scope
                                            .where.not(status: Telephony::CallSession::TERMINAL_STATUSES)
                                            .order(created_at: :desc, id: :desc)
                                            .pick(:external_call_ref)
  end

  def recent_bridge_call_session_scope
    Telephony::CallSession.where(account_id: number_binding.account_id, conversation_id: existing_voice_conversation.id)
                          .where.not(external_call_ref: call_ref)
                          .where('created_at >= ?', 2.minutes.ago)
  end

  def logical_bridge_call_ref_for_context
    @logical_bridge_call_ref_for_context ||= begin
      session = recent_logical_bridge_call_session_scope
                .where.not(status: Telephony::CallSession::TERMINAL_STATUSES)
                .order(created_at: :desc, id: :desc)
                .detect { |candidate| logical_group_ref_for_session(candidate).present? || candidate.external_call_ref.present? }
      logical_group_ref_for_session(session).presence || session&.external_call_ref
    end
  end

  def logical_group_ref_for_session(session)
    return if session.blank?

    metadata = session.metadata.to_h.deep_stringify_keys
    route_metadata = metadata['metadata'].is_a?(Hash) ? metadata['metadata'] : {}
    last_payload = metadata['last_payload'].is_a?(Hash) ? metadata['last_payload'] : {}
    nested_payload = last_payload['payload'].is_a?(Hash) ? last_payload['payload'] : {}

    route_metadata['logical_call_group_ref'].presence ||
      route_metadata['bridge_call_ref'].presence || route_metadata['bridgeCallRef'].presence ||
      last_payload['bridge_call_ref'].presence || last_payload['bridgeCallRef'].presence ||
      nested_payload['bridge_call_ref'].presence || nested_payload['bridgeCallRef'].presence
  end

  def recent_logical_bridge_call_session_scope
    scope = Telephony::CallSession.where(
      account_id: number_binding.account_id,
      inbox_id: number_binding.inbox_id,
      number_binding_id: number_binding.id,
      direction: 'inbound'
    )
                                  .where.not(external_call_ref: call_ref)
                                  .where('created_at >= ?', 20.seconds.ago)
    scope = scope.where(conversation_id: existing_voice_conversation.id) if existing_voice_conversation.present?
    scope = scope.where(from_number: recent_context_from_numbers) if recent_context_from_numbers.present?
    scope = scope.where(to_number: recent_context_to_numbers) if recent_context_to_numbers.present?
    scope
  end

  def recent_context_from_numbers
    [caller_number, normalized_caller_number].compact_blank.uniq
  end

  def recent_context_to_numbers
    [inbound_number, number_binding.phone_number].compact_blank.uniq
  end

  def conversation_from_call_ref
    return if call_ref.blank?

    conversation_scope.find_by(identifier: call_ref)
  end

  def conversation_from_caller_number
    return if caller_number.blank?

    source_values = [caller_number, normalized_caller_number].compact.uniq
    return if source_values.blank?

    conditions = []
    bind_values = []
    if normalized_caller_number.present?
      conditions << 'contacts.phone_number = ?'
      bind_values << normalized_caller_number
    end
    conditions << 'contact_inboxes.source_id IN (?)'
    bind_values << source_values

    conversation_scope
      .joins(:contact, :contact_inbox)
      .where(conditions.join(' OR '), *bind_values)
      .first
  end

  def conversation_scope
    number_binding.account.conversations
                  .where(inbox_id: number_binding.inbox_id)
                  .order(updated_at: :desc, id: :desc)
  end

  def normalized_caller_number
    @normalized_caller_number ||= normalize_phone_number(caller_number)
  end

  def call_ref
    payload_value('call_ref', 'callRef', 'call_sid', 'callSid')
  end

  def caller_number
    value = payload_value('caller_number', 'callerNumber', 'from_number', 'fromNumber', 'from')
    normalize_phone_number(value) || value
  end

  def normalize_target_number(value)
    raw_value = value.to_s.strip
    return if raw_value.blank?

    dialable_value = raw_value.sub(/\Atel:/i, '')
    dialable_value = dialable_value[/\A<?sip:([^@;>]+)/i, 1] || dialable_value
    dialable_value = dialable_value.split(/[;?]/).first.to_s.strip

    normalize_phone_number(dialable_value) || dialable_value
  end

  def normalize_phone_number(value)
    Contacts::PhoneNumberNormalizer.normalize(value) ||
      Contacts::PhoneNumberNormalizer.normalize(value, default_country: 'KZ')
  end

  def number_binding
    @number_binding ||= resolve_number_binding
  end

  def resolve_number_binding
    scope = ordered_number_binding_scope
    scoped = constrain_number_binding_scope(scope)
    binding = find_number_binding(scoped)

    return binding if binding.present? || route_scope_constrained?

    find_number_binding(scope)
  end

  def ordered_number_binding_scope
    Telephony::NumberBinding
      .includes(:routing_policy, inbox: :working_hours)
      .order(:id)
  end

  def constrain_number_binding_scope(scope)
    scope = scope.where(account_id: route_account_id) if route_account_id.present?
    scope = scope.where(inbox_id: route_inbox_id) if route_inbox_id.present?
    scope
  end

  def route_scope_constrained?
    route_account_id.present? || route_inbox_id.present?
  end

  def find_number_binding(scope)
    if (number_ref = payload_value('number_ref', 'numberRef')).present?
      scope.find_by(number_ref: number_ref)
    elsif inbound_number.present?
      scope.find_by(phone_number: inbound_number) || scope.find_by(ingress_number: inbound_number)
    end
  end

  def route_account_id
    @route_account_id ||= payload_value('account_id', 'accountId', 'chatwoot_account_id', 'chatwootAccountId') ||
                          metadata_value('onelink_account_id', 'account_id', 'accountId', 'chatwoot_account_id', 'chatwootAccountId')
  end

  def route_inbox_id
    @route_inbox_id ||= payload_value('inbox_id', 'inboxId', 'chatwoot_inbox_id', 'chatwootInboxId') ||
                        metadata_value('onelink_inbox_id', 'inbox_id', 'inboxId', 'chatwoot_inbox_id', 'chatwootInboxId')
  end

  def inbound_number
    value = payload_value('ingress_number', 'ingressNumber', 'to_number', 'toNumber', 'to')
    normalize_target_number(value) || value
  end

  def metadata_value(*keys)
    keys.each do |key|
      value = metadata_payload[key.to_s] || metadata_payload[key.to_sym]
      return value if value.present?
    end

    nil
  end

  def sipuni_leg_metadata
    return {} unless sipuni_provider?
    return {} unless sipuni_operator_leg_known?

    {
      sipuni_operator_leg: sipuni_operator_leg?,
      sipuni_leg_kind: sipuni_operator_leg? ? 'operator' : 'external'
    }
  end

  def sipuni_pre_operator_leg?
    sipuni_provider? && sipuni_operator_leg_known? && !sipuni_operator_leg?
  end

  def sipuni_provider?
    payload_value('provider').to_s == 'sipuni' || number_binding&.provider.to_s == 'sipuni'
  end

  def sipuni_operator_leg_known?
    raw_payload_key?('operator_leg', 'operatorLeg') || raw_metadata_key?('sipuni_operator_leg', 'sipuniOperatorLeg')
  end

  def sipuni_operator_leg?
    value = raw_payload_value('operator_leg', 'operatorLeg')
    value = raw_metadata_value('sipuni_operator_leg', 'sipuniOperatorLeg') if value.nil?
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def raw_metadata_key?(*keys)
    keys.any? { |key| metadata_payload.key?(key.to_s) || metadata_payload.key?(key.to_sym) }
  end

  def raw_metadata_value(*keys)
    keys.each do |key|
      return metadata_payload[key.to_s] if metadata_payload.key?(key.to_s)
      return metadata_payload[key.to_sym] if metadata_payload.key?(key.to_sym)
    end

    nil
  end

  def raw_payload_key?(*keys)
    keys.any? { |key| payload.key?(key.to_s) || payload.key?(key.to_sym) }
  end

  def raw_payload_value(*keys)
    keys.each do |key|
      return payload[key.to_s] if payload.key?(key.to_s)
      return payload[key.to_sym] if payload.key?(key.to_sym)
    end

    nil
  end

  def metadata_payload
    @metadata_payload ||= begin
      metadata = payload['metadata']
      metadata.is_a?(Hash) ? metadata : {}
    end
  end

  def payload_value(*keys)
    keys.each do |key|
      value = payload[key.to_s]
      return value if value.present?
    end

    nil
  end
end
