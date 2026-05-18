class Telephony::InboundRoutingService
  DEFAULT_REJECT_MESSAGE = 'We are unable to connect your call right now.'.freeze
  OPERATOR_CANDIDATE_LIMIT = 20

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

    ensure_route_lifecycle!(decision)
    decision
  end

  private

  attr_reader :payload

  def routed_decision
    recursive_runtime_decision = recursive_runtime_call_active_decision
    return recursive_runtime_decision if recursive_runtime_decision.present?

    status_decision = status_aware_conversation_decision
    return status_decision if status_decision.present?

    return out_of_office_decision if inbox&.out_of_office?

    primary_decision
  end

  def out_of_office_decision
    return reject_decision(reason: 'out_of_office', prefer_out_of_office_message: true) if routing_policy.operator_mode?

    fallback_decision(reason: 'out_of_office', prefer_out_of_office_message: true)
  end

  def primary_decision
    case routing_policy.mode
    when 'operator'
      return operator_decision(reason: 'operator_route') if operator_routable?

      reject_decision(reason: 'operator_unavailable')
    when 'app'
      return app_decision(reason: 'app_route') if resolved_primary_app_ref.present?

      fallback_decision(reason: primary_app_failure_reason)
    when 'ai'
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
    return ai_decision(reason: 'pending_conversation_ai_route') if resolved_ai_app_ref.present?

    fallback_decision(reason: ai_app_failure_reason)
  end

  def ensure_route_lifecycle!(decision)
    return if number_binding.blank?
    return if call_ref.blank? || caller_number.blank?
    return if diagnostic_route_probe?

    Telephony::EventsIngestionService.new(payload: route_lifecycle_payload(decision)).perform
  end

  def route_lifecycle_payload(decision)
    metadata = {
      route_action: decision[:action] || decision['action'],
      route_reason: decision[:reason] || decision['reason']
    }

    metadata.merge!(operator_route_metadata(decision)) if operator_decision?(decision)

    if existing_voice_conversation.present?
      metadata[:chatwoot_conversation_id] = existing_voice_conversation.id
      metadata[:chatwoot_conversation_status] = existing_voice_conversation.status
    end

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
      metadata: metadata.compact
    }.compact
  end

  def operator_route_metadata(decision)
    candidates = decision[:operator_candidates] || decision['operator_candidates'] || []
    return {} if candidates.blank?

    candidate_hashes = candidates.map { |candidate| candidate.deep_stringify_keys }
    {
      operator_pool: true,
      operator_pool_size: candidate_hashes.size,
      operator_candidates: candidate_hashes,
      operator_candidate_binding_ids: candidate_hashes.filter_map { |candidate| candidate['id'] },
      operator_candidate_user_ids: candidate_hashes.filter_map { |candidate| candidate['user_id'] },
      operator_candidate_agent_refs: candidate_hashes.filter_map { |candidate| candidate['agent_ref'] },
      operator_candidate_agent_aors: candidate_hashes.filter_map { |candidate| candidate['agent_aor'] }
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

  def fallback_decision(reason:, prefer_out_of_office_message: false, prefer_ai: false)
    fallback_order(prefer_ai: prefer_ai).each do |mode|
      case mode
      when 'operator'
        return operator_decision(reason: reason) if operator_routable?
      when 'ai'
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

  def resolved_operator_aor
    primary_operator_candidate&.agent_aor.presence || operator_binding&.agent_aor.presence || routing_policy.operator_agent_aor
  end

  def sip_operator_aor?(value)
    value.to_s.downcase.start_with?('sip:')
  end

  def operator_binding
    @operator_binding ||= configured_operator_binding
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

  def operator_candidates
    @operator_candidates ||= begin
      candidates = operator_candidate_scope.select do |binding|
        binding.enabled? && binding.registered_for_routing? && sip_operator_aor?(binding.agent_aor)
      end
      busy_ids = busy_operator_binding_ids(candidates.map(&:id))
      candidates = candidates.reject { |binding| busy_ids.include?(binding.id) }

      candidates.sort_by { |binding| operator_candidate_sort_key(binding) }.first(OPERATOR_CANDIDATE_LIMIT)
    end
  end

  def primary_operator_candidate
    operator_candidates.first
  end

  def operator_candidate_scope
    scope = number_binding.account.telephony_agent_bindings.includes(:user)
    scope = scope.where(user_id: inbox.members.select(:id)) if inbox.present? && inbox.inbox_members.exists?
    scope
  end

  def busy_operator_binding_ids(candidate_ids)
    return [] if candidate_ids.blank?

    Telephony::CallSession.active
                          .where(account_id: number_binding.account_id, agent_binding_id: candidate_ids)
                          .where.not(external_call_ref: call_ref)
                          .distinct
                          .pluck(:agent_binding_id)
  end

  def operator_candidate_sort_key(binding)
    preferred = binding.id == configured_operator_binding&.id ? 0 : 1
    [preferred, binding.user_id || 0, binding.id]
  end

  def configured_operator_binding
    @configured_operator_binding ||= begin
      scope = number_binding.account.telephony_agent_bindings
      if routing_policy.operator_agent_ref.present?
        scope.find_by(agent_ref: routing_policy.operator_agent_ref)
      elsif routing_policy.operator_agent_aor.present?
        scope.find_by(agent_aor: routing_policy.operator_agent_aor)
      end
    end
  end

  def operator_candidate_payload(binding)
    {
      id: binding.id,
      agent_ref: binding.agent_ref,
      agent_aor: binding.agent_aor,
      user_id: binding.user_id,
      name: binding.user&.name
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
    }.merge(shared_context)
  end

  def ai_decision(reason:)
    {
      action: 'ai',
      ai_mode: routing_policy.ai_deployment_mode,
      app_ref: resolved_ai_app_ref,
      reason: reason
    }.merge(shared_context)
  end

  def reject_decision(reason:, prefer_out_of_office_message: false)
    {
      action: 'reject',
      message: reject_message(prefer_out_of_office_message: prefer_out_of_office_message),
      reason: reason
    }.merge(shared_context)
  end

  def reject_message(prefer_out_of_office_message: false)
    return inbox.out_of_office_message if prefer_out_of_office_message && inbox&.out_of_office_message.present?
    return routing_policy.fallback_message if routing_policy&.fallback_message.present?
    return inbox.out_of_office_message if inbox&.out_of_office_message.present?

    DEFAULT_REJECT_MESSAGE
  end

  def recursive_runtime_call_active_decision
    return unless direct_onelink_ai_runtime_request?
    return if existing_voice_conversation.blank?
    return if active_bridge_call_ref_for_context.blank?

    reject_decision(reason: 'recursive_runtime_call_active')
  end

  def shared_context
    return {} if number_binding.blank?

    context = {
      account_id: number_binding.account_id,
      inbox_id: number_binding.inbox_id,
      number_ref: number_binding.number_ref,
      bridge_call_ref: bridge_call_ref_for_context,
      recording: recording_payload
    }

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

  def resolved_primary_app_ref
    @resolved_primary_app_ref ||= routable_app_ref(number_binding&.configured_app_ref)
  end

  def resolved_ai_app_ref
    @resolved_ai_app_ref ||= if direct_onelink_ai_runtime_request?
                               routing_policy.effective_ai_app_ref
                             else
                               routable_app_ref(routing_policy&.effective_ai_app_ref)
                             end
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

  def existing_voice_conversation
    @existing_voice_conversation ||= conversation_from_call_ref || conversation_from_caller_number
  end

  def bridge_call_ref_for_context
    return if existing_voice_conversation.blank?

    @bridge_call_ref_for_context ||= active_bridge_call_ref_for_context ||
                                     recent_bridge_call_session_scope.order(created_at: :desc, id: :desc).pick(:external_call_ref)
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
    @normalized_caller_number ||= Contacts::PhoneNumberNormalizer.normalize(caller_number)
  end

  def call_ref
    payload_value('call_ref', 'callRef', 'call_sid', 'callSid')
  end

  def caller_number
    payload_value('caller_number', 'callerNumber', 'from_number', 'fromNumber', 'from')
  end

  def number_binding
    @number_binding ||= begin
      scope = Telephony::NumberBinding.includes(:routing_policy, inbox: :working_hours)
      if (number_ref = payload_value('number_ref', 'numberRef')).present?
        scope.find_by(number_ref: number_ref)
      elsif inbound_number.present?
        scope.find_by(phone_number: inbound_number)
      end
    end
  end

  def inbound_number
    payload_value('ingress_number', 'ingressNumber', 'to_number', 'toNumber', 'to')
  end

  def payload_value(*keys)
    keys.each do |key|
      value = payload[key.to_s]
      return value if value.present?
    end

    nil
  end
end
