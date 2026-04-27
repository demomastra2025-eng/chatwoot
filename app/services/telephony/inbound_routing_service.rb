class Telephony::InboundRoutingService
  DEFAULT_REJECT_MESSAGE = 'We are unable to connect your call right now.'.freeze

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    return reject_decision(reason: 'number_not_bound') if number_binding.blank?
    return reject_decision(reason: 'routing_policy_missing') if routing_policy.blank?

    status_decision = status_aware_conversation_decision
    return status_decision if status_decision.present?

    return fallback_decision(reason: 'out_of_office', prefer_out_of_office_message: true) if inbox&.out_of_office?

    primary_decision
  end

  private

  attr_reader :payload

  def primary_decision
    case routing_policy.mode
    when 'operator'
      return operator_decision(reason: 'operator_route') if operator_available?

      fallback_decision(reason: 'operator_unavailable')
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
    return unless ai_routing_enabled?
    return if existing_voice_conversation.blank?

    return pending_conversation_ai_decision if existing_voice_conversation.pending?

    non_pending_conversation_operator_decision
  end

  def pending_conversation_ai_decision
    return ai_decision(reason: 'pending_conversation_ai_route') if resolved_ai_app_ref.present?

    fallback_decision(reason: ai_app_failure_reason)
  end

  def non_pending_conversation_operator_decision
    return operator_decision(reason: 'non_pending_conversation_operator_route') if operator_available?

    fallback_decision(reason: 'operator_unavailable')
  end

  def ai_routing_enabled?
    routing_policy.ai_enabled? || routing_policy.ai_mode?
  end

  def fallback_decision(reason:, prefer_out_of_office_message: false)
    fallback_order.each do |mode|
      case mode
      when 'operator'
        return operator_decision(reason: reason) if operator_available?
      when 'ai'
        return ai_decision(reason: reason) if resolved_ai_app_ref.present?
      when 'app'
        return app_decision(reason: reason) if resolved_primary_app_ref.present?
      end
    end

    reject_decision(reason: reason, prefer_out_of_office_message: prefer_out_of_office_message)
  end

  def fallback_order
    case routing_policy.fallback_mode
    when 'operator'
      %w[operator app]
    when 'app'
      %w[app operator]
    when 'ai'
      %w[ai operator app]
    else
      []
    end
  end

  def operator_available?
    return false if resolved_operator_aor.blank?

    return true if operator_binding.blank?

    operator_binding.enabled?
  end

  def resolved_operator_aor
    operator_binding&.agent_aor.presence || routing_policy.operator_agent_aor
  end

  def operator_binding
    @operator_binding ||= begin
      scope = number_binding.account.telephony_agent_bindings
      if routing_policy.operator_agent_ref.present?
        scope.find_by(agent_ref: routing_policy.operator_agent_ref)
      elsif routing_policy.operator_agent_aor.present?
        scope.find_by(agent_aor: routing_policy.operator_agent_aor)
      end
    end
  end

  def operator_decision(reason:)
    {
      action: 'operator',
      reason: reason
    }.merge(routing_policy.operator_target_payload).merge(shared_context)
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

  def shared_context
    return {} if number_binding.blank?

    {
      account_id: number_binding.account_id,
      inbox_id: number_binding.inbox_id,
      number_ref: number_binding.number_ref
    }
  end

  def routing_policy
    @routing_policy ||= number_binding&.routing_policy
  end

  def resolved_primary_app_ref
    @resolved_primary_app_ref ||= routable_app_ref(number_binding&.configured_app_ref)
  end

  def resolved_ai_app_ref
    @resolved_ai_app_ref ||= routable_app_ref(routing_policy&.ai_app_ref)
  end

  def primary_app_failure_reason
    number_binding&.configured_app_ref.present? ? 'recursive_runtime_app_ref' : 'app_ref_missing'
  end

  def ai_app_failure_reason
    routing_policy&.ai_app_ref.present? ? 'recursive_runtime_app_ref' : 'ai_app_ref_missing'
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
