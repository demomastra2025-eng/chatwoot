# frozen_string_literal: true

require 'timeout'

# The second opinion of the router: a strong reasoning chat model (not a decision model) gets the same state and the same
# questions (names, criteria keys and descriptions) when the decision models answered with low confidence, when their answers
# contradicted each other, or when the turn would bounce straight back. It answers every question with one of its keys, plus a
# short reason, as structured output; the router composes the answers exactly as for a decision model, and the result is final.
# It never sees what the decision models answered, so it cannot anchor on it. Any failure (an error, the timeout, an answer
# outside the keys) raises Captain::Runtime::DecisionRouter::EscalationError: the router then uses the outcome the decision models'
# answers composed into (DecisionRouter#chain_fallback), and without one the turn ends through the technical-failure path, the same
# as when every decision model failed.
class Captain::Runtime::DecisionRouter::Escalation
  FEATURE = :agent_routing_escalation
  REASON_LIMIT = 200
  Answer = Struct.new(:choices, :reason, :model, keyword_init: true)
  PROMPT_TAIL = 'A fast classifier was not confident about this message, or its answers did not agree. Think it through and answer ' \
                'every question with exactly one of its keys, so that the answers agree, and give reason (at most 200 characters, ' \
                'naming agents by id and services by category; never quote the patient).'

  def initialize(account:, timeout:, effort:, observability: {}, model: nil)
    @account = account
    @timeout = timeout.to_f
    @effort = effort
    @observability = observability.to_h
    @model = model.presence || Llm::Config.model_for(feature: FEATURE, account: account)
  end

  attr_reader :model

  # questions: Captain::Runtime::DecisionRouter::Questions; state: the Hash the decision models read.
  def choose(state:, questions:, instructions:)
    raise_failed('escalation_unavailable', 'no_model') if @model.blank?

    content = Timeout.timeout(@timeout) { ask(state, questions, instructions) }
    choices, reason = parse(content, questions)
    raise_failed('escalation_invalid', 'invalid_choice') unless choices

    Answer.new(choices: choices, reason: sanitized(reason), model: @model)
  rescue Captain::Runtime::DecisionRouter::EscalationError, Captain::Conversation::ControlGenerationStaleError
    raise
  rescue Timeout::Error
    raise_failed('escalation_unavailable', 'timeout')
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Router] escalation failed error_class=#{e.class.name}")
    raise_failed('escalation_unavailable', e.class.name)
  end

  private

  def ask(state, questions, instructions)
    chat = Llm::Runtime.build_chat(
      feature: FEATURE, account: @account, model: @model, models: [@model], server_tools: [], transform_policy: 'disabled',
      options: Llm::ModelParameters.for(@model, account: @account).compile(thinking: thinking)
    )
    chat = chat.with_instructions(system_prompt(questions, instructions))
    chat = Llm::StructuredOutputPolicy.bind!(chat: chat, schema: schema(questions))
    response = Llm::Runtime.ask(chat, state.to_json, account: @account, model: @model,
                                                     observability: @observability.merge(operation: 'captain.agent_routing_escalation'))
    response.respond_to?(:content) ? response.content : response
  end

  def thinking
    contract = Llm::ModelParameters.for(@model, account: @account)
    contract.thinking(@effort) || contract.thinking('high') || contract.thinking('medium')
  end

  def system_prompt(questions, instructions)
    sections = questions.to_h.map do |name, question|
      lines = question[:criteria].map { |key, description| "- #{key}: #{description}" }
      "Question #{name} (answer with one key):\n#{lines.join("\n")}"
    end
    [instructions, "Every include_agent question: #{Captain::Runtime::DecisionRouter::Questions::INCLUDE_INSTRUCTIONS}",
     *sections, PROMPT_TAIL].join("\n\n")
  end

  def schema(questions)
    properties = questions.to_h.transform_values { |question| { type: 'string', enum: question[:criteria].keys } }
    {
      name: 'captain_agent_routing_escalation', strict: true,
      schema: { type: 'object', additionalProperties: false, properties: properties.merge('reason' => { type: 'string' }),
                required: [*properties.keys, 'reason'] }
    }
  end

  # [{ name => key }, reason], or nil when an answer is missing or outside its keys.
  def parse(content, questions)
    content = structured(content)
    return unless content

    choices = questions.to_h.to_h { |name, _question| [name, content[name].to_s] }
    return unless questions.to_h.all? { |name, question| question[:criteria].key?(choices[name]) }

    [choices, content[:reason].to_s]
  end

  # The structured answer as a Hash (the provider may hand it back parsed or as JSON text), or nil.
  def structured(content)
    content = JSON.parse(content) if content.is_a?(String) && content.strip.start_with?('{')
    content.with_indifferent_access if content.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end

  def sanitized(reason)
    reason.to_s.gsub(/[\r\n\t]+/, ' ').squish.first(REASON_LIMIT)
  end

  def raise_failed(reason, detail)
    raise Captain::Runtime::DecisionRouter::EscalationError.new(reason: reason, detail: detail, models_tried: [@model].compact)
  end
end
