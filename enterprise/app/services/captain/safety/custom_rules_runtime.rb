# frozen_string_literal: true

require 'digest'

# Applies saved business checks without giving the classifier any tools or authority to send messages.
class Captain::Safety::CustomRulesRuntime
  RESPONSE_KEY = 'custom_guardrail'.freeze
  INPUT_CACHE_KEY = :captain_custom_input_checks

  class HandoffRequired < StandardError
    attr_reader :assistant_id, :result

    def initialize(assistant_id:, result:)
      @assistant_id, @result = assistant_id, result
      super('A configured safety check stopped the automatic reply')
    end
  end

  def self.check_input!(assistant:, context:, text: nil)
    text ||= context[:captain_v2_current_input]
    return if text.nil?

    candidate = text_content(text)
    settings = Captain::AccountSettings.new(assistant.account).section('safety')['custom_rules']
    fingerprint = Digest::SHA256.hexdigest([assistant.account_id, candidate, settings].to_json)
    checks = context[INPUT_CACHE_KEY] ||= []
    return if checks.include?(fingerprint)

    result = evaluate(assistant: assistant, direction: 'input', text: candidate, context: context)
    raise HandoffRequired.new(assistant_id: assistant.id, result: result) unless result.allowed?

    checks << fingerprint
  end

  def self.check_output!(assistant:, context:, response:)
    result = evaluate(assistant: assistant, direction: 'output', text: response['response'], context: context)
    return response if result.allowed?
    raise HandoffRequired.new(assistant_id: assistant.id, result: result) unless result.matched? && result.action == 'rewrite'

    replacement = Captain::Safety::ResponseRewriteEngine.new.rewrite(
      assistant: assistant, text: response['response'], rule_id: result.rule_id,
      last_customer_message: customer_message(context)
    )
    raise HandoffRequired.new(assistant_id: assistant.id, result: result) if replacement.blank?

    # Exactly one text-only repair. A second match or unavailable checker stops the turn.
    checked = evaluate(assistant: assistant, direction: 'output', text: replacement, context: context)
    raise HandoffRequired.new(assistant_id: assistant.id, result: checked) unless checked.allowed?

    Llm::SafetyPolicy.check!(
      feature: :assistant, stage: :output, content: replacement, account: assistant.account,
      preferences: context.dig(:state, :captain_runtime)
    )
    response.merge('response' => replacement, 'reasoning' => 'Response revised by a configured safety rule.')
  end

  def self.response_for(error)
    result = error.result
    {
      'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE,
      Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_AUTHORIZED_KEY => true,
      'agent_id' => error.assistant_id,
      'reasoning' => 'Automatic reply stopped by a configured safety check.',
      RESPONSE_KEY => {
        'direction' => result.direction, 'rule_id' => result.rule_id, 'action' => result.action,
        'model' => result.model, 'latency_ms' => result.latency_ms, 'reason' => result.reason.to_s
      }.compact
    }
  end

  def self.evaluate(assistant:, direction:, text:, context:)
    facts = { locale: assistant.account.locale.to_s, source: context[:source].to_s }
    facts[:last_customer_message] = customer_message(context) if direction == 'output'
    result = Captain::Safety::CustomRulesEvaluator.evaluate(assistant: assistant, direction: direction, text: text, context: facts)
    Llm::EventBus.publish(
      'safety.custom_rule', feature: :assistant, stage: direction, assistant_id: assistant.id,
      rule: result.rule_id, action: result.action, status: result.status.to_s,
      model: result.model, duration_ms: result.latency_ms, reason: result.reason
    ) unless result.reason == :no_enabled_rules
    result
  end

  def self.customer_message(context)
    text_content(context[:captain_v2_current_input]).last(Captain::Safety::CustomRulesEvaluator::MAX_CUSTOMER_MESSAGE_LENGTH)
  end

  def self.text_content(content)
    case content
    when RubyLLM::Content then content.text.to_s
    when Array
      content.filter_map do |part|
        part = part.with_indifferent_access if part.is_a?(Hash)
        part[:text] if part.is_a?(Hash) && part[:type].to_s == 'text'
      end.join("\n")
    else content.to_s
    end
  end

  private_class_method :evaluate, :customer_message, :text_content
end
