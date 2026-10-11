# frozen_string_literal: true

class Captain::Safety::CustomRulesEvaluator
  MAX_TEXT_LENGTH = 10_000
  MAX_CONTEXT_VALUE_LENGTH = 120
  MAX_CUSTOMER_MESSAGE_LENGTH = 2000
  CONTEXT_FIELDS = %w[conversation_status channel_type locale source].freeze
  Result = Struct.new(:status, :direction, :rule_id, :action, :message, :model, :latency_ms, :reason, keyword_init: true) do
    def allowed? = status == :allowed
    def matched? = status == :matched
    def unavailable? = status == :unavailable
  end

  def self.evaluate(**attributes)
    new.evaluate(**attributes)
  end

  # An engine only selects an ID. Actions and public messages always come from the saved profile.
  def initialize(engine: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @engine = engine
    @clock = clock
  end

  def evaluate(assistant:, direction:, text:, context: {})
    @direction = direction.to_s
    @model = nil
    @started_at = nil
    return unavailable(:invalid_direction) unless Captain::Safety::CustomRulesConfig::DIRECTIONS.include?(@direction)
    return result(:allowed, reason: :inactive_assistant) unless assistant.active?

    rules = configured_rules(assistant)
    return unavailable(:invalid_configuration) if rules.nil?

    rules = rules.select { |rule| rule['enabled'] && rule['direction'] == @direction }
    return result(:allowed, reason: :no_enabled_rules) if rules.empty?

    evaluate_rules(assistant, rules, text, context)
  rescue Captain::Safety::CustomRulesStructuredOutputEngine::UnavailableError => e
    unavailable(e.code, error: e)
  rescue StandardError => e
    unavailable(:engine_unavailable, error: e)
  end

  private

  def evaluate_rules(assistant, rules, text, context)
    return unavailable(:invalid_text) unless text.is_a?(String)
    return unavailable(:text_too_long) if text.length > MAX_TEXT_LENGTH

    safe_context = validated_context(context)
    return unavailable(:invalid_context) if safe_context.nil?

    engine = @engine || Captain::Safety::CustomRulesStructuredOutputEngine.new(account: assistant.account)
    @started_at = @clock.call
    @model = engine.model
    payload = response_payload(engine.select(model: @model, rules: rules, direction: @direction, text: text, context: safe_context))
    return unavailable(:invalid_response) unless valid_selection?(payload, rules)
    return result(:allowed) if payload['rule_id'] == Captain::Safety::CustomRulesConfig::NONE_ID

    rule = rules.find { |item| item['id'] == payload['rule_id'] }
    result(:matched, rule_id: rule['id'], action: rule['action'], message: rule['message'])
  end

  def configured_rules(assistant)
    rules = Captain::AccountSettings.new(assistant.account).runtime_rules
    Captain::Safety::CustomRulesConfig.errors(rules).empty? ? rules : nil
  end

  def validated_context(context)
    return unless context.is_a?(Hash)

    context = context.stringify_keys
    fields = CONTEXT_FIELDS.dup
    fields << 'last_customer_message' if @direction == 'output'
    fields.each_with_object({}) do |field, safe_context|
      next unless context.key?(field)

      value = context[field]
      maximum = field == 'last_customer_message' ? MAX_CUSTOMER_MESSAGE_LENGTH : MAX_CONTEXT_VALUE_LENGTH
      return nil unless value.is_a?(String) && value.length <= maximum

      safe_context[field] = value
    end
  end

  def response_payload(response)
    payload = response.respond_to?(:content) ? response.content : response
    payload = JSON.parse(payload) if payload.is_a?(String)
    payload.is_a?(Hash) ? payload.stringify_keys : nil
  rescue JSON::ParserError
    nil
  end

  def valid_selection?(payload, rules)
    payload.is_a?(Hash) && payload.keys == ['rule_id'] && payload['rule_id'].is_a?(String) &&
      (payload['rule_id'] == Captain::Safety::CustomRulesConfig::NONE_ID || rules.any? { |rule| rule['id'] == payload['rule_id'] })
  end

  def unavailable(reason, error: nil)
    if error
      Rails.logger.warn("[Captain::Safety::CustomRulesEvaluator] unavailable code=#{reason} error_class=#{error.class.name}")
    end
    result(:unavailable, reason: reason)
  end

  def result(status, **attributes)
    latency = @started_at ? ((@clock.call - @started_at) * 1000).round : 0
    Result.new(status: status, direction: @direction, model: @model, latency_ms: latency, **attributes).freeze
  end
end
