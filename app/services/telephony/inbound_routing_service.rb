class Telephony::InboundRoutingService
  DEFAULT_REJECT_MESSAGE = 'We are unable to connect your call right now.'.freeze

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    return reject_decision(reason: 'number_not_bound') if number_binding.blank?
    return reject_decision(reason: 'routing_policy_missing') if routing_policy.blank?

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
      return app_decision(reason: 'app_route') if number_binding.configured_app_ref.present?

      fallback_decision(reason: 'app_ref_missing')
    when 'ai'
      return ai_decision(reason: 'ai_route') if routing_policy.ai_app_ref.present?

      fallback_decision(reason: 'ai_app_ref_missing')
    when 'reject'
      reject_decision(reason: 'reject_route')
    else
      fallback_decision(reason: 'unsupported_mode')
    end
  end

  def fallback_decision(reason:, prefer_out_of_office_message: false)
    fallback_order.each do |mode|
      case mode
      when 'operator'
        return operator_decision(reason: reason) if operator_available?
      when 'app'
        return app_decision(reason: reason) if number_binding.configured_app_ref.present?
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
      agent_aor: resolved_operator_aor,
      reason: reason
    }.merge(shared_context)
  end

  def app_decision(reason:)
    {
      action: 'app',
      app_ref: number_binding.configured_app_ref,
      reason: reason
    }.merge(shared_context)
  end

  def ai_decision(reason:)
    {
      action: 'ai',
      app_ref: routing_policy.ai_app_ref,
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

  def inbox
    @inbox ||= number_binding&.inbox
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
