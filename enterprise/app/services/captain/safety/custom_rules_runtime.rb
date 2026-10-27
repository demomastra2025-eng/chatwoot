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

  # The rules are a workspace setting, the same for every agent, so a check belongs to the account. agent_id is the agent that a
  # stopped turn is attributed to (the holder of the conversation, or nil when nobody holds it: the AI itself).
  def self.check_input!(account:, context:, text: nil, agent_id: nil)
    text ||= context[:captain_v2_current_input]
    return if text.nil?

    candidate = text_content(text)
    settings = Captain::AccountSettings.new(account).section('safety')['custom_rules']
    fingerprint = Digest::SHA256.hexdigest([account.id, candidate, settings].to_json)
    checks = context[INPUT_CACHE_KEY] ||= []
    return if checks.include?(fingerprint)

    result = evaluate(account: account, direction: 'input', text: candidate, context: context)
    raise HandoffRequired.new(assistant_id: agent_id, result: result) if result.matched?

    checks << fingerprint
  end

  def self.check_output!(account:, context:, response:, agent_id: nil)
    result = evaluate(account: account, direction: 'output', text: response['response'], context: context)
    return response unless result.matched?
    raise HandoffRequired.new(assistant_id: agent_id, result: result) unless result.action == 'rewrite'

    replacement = Captain::Safety::ResponseRewriteEngine.new.rewrite(
      account: account, text: response['response'], rule_id: result.rule_id,
      last_customer_message: customer_message(context)
    )
    raise HandoffRequired.new(assistant_id: agent_id, result: result) if replacement.blank?

    # Exactly one text-only repair. A second match stops the turn.
    checked = evaluate(account: account, direction: 'output', text: replacement, context: context)
    raise HandoffRequired.new(assistant_id: agent_id, result: checked) if checked.matched?

    Llm::SafetyPolicy.check!(
      feature: :assistant, stage: :output, content: replacement, account: account,
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

  def self.evaluate(account:, direction:, text:, context:)
    facts = { locale: account.locale.to_s, source: context[:source].to_s }
    facts[:last_customer_message] = customer_message(context) if direction == 'output'
    result = Captain::Safety::CustomRulesEvaluator.evaluate(account: account, direction: direction, text: text, context: facts)
    Llm::EventBus.publish(
      'safety.custom_rule', feature: :assistant, stage: direction, account_id: account.id, assistant_id: context.dig(:state, :assistant_id),
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
