# frozen_string_literal: true

# One decision inside a patient turn, asked down the platform chain of decision models: the first model that answers in
# time wins; a model that fails, times out or answers outside the criteria passes the same question to the next one.
# Every call is an ordinary Llm::Runtime.decide (budgets, headers, one llm.decision.complete event each, marked with its
# position in the chain). When no model answers, ExhaustedError is raised: the caller ends the turn through its
# technical-failure path, the same as when OpenRouter is down for generation.
#
# The chain of a feature: agent_routing has its own (installation config CAPTAIN_AGENT_ROUTING_MODELS, built in Perplexity
# Decider, then Mercury Decide, then Microsoft Decision 1: the owner's choice of 25.10 after the router benchmark); every other
# turn decision feature uses the shared chain CAPTAIN_DECISION_MODEL_CHAIN.
class Llm::DecisionChain
  CONFIG_NAME = 'CAPTAIN_DECISION_MODEL_CHAIN'
  DEFAULT_MODELS = %w[inception/mercury-decide microsoft/microsoft-decision-1 openai/gpt-6-luna-decisions].freeze
  FEATURE_CHAINS = {
    'agent_routing' => { config: 'CAPTAIN_AGENT_ROUTING_MODELS',
                         default: %w[perplexity/pplx-decider-v1.2 inception/mercury-decide microsoft/microsoft-decision-1].freeze },
    'reply_claim_check' => { config: 'CAPTAIN_REPLY_CLAIM_CHECK_MODELS',
                             default: %w[microsoft/microsoft-decision-1 perplexity/pplx-decider-v1.2].freeze }
  }.freeze
  MAX_MODELS = 3
  # Below this a call cannot finish, so the chain stops instead of starting it.
  MIN_ATTEMPT_SECONDS = 0.3

  # model: the model of the chain that answered; served_model: the dated model OpenRouter actually ran; position: 1 for the head.
  # answers: for a question set, one Llm::OpenRouterDecisionClient::Answer per question (choice and confidence are then the
  # summary and the lowest confidence of the answers).
  Result = Struct.new(:choice, :confidence, :probabilities, :answers, :model, :served_model, :position, keyword_init: true) do
    def fallback? = position.to_i > 1
  end

  class ExhaustedError < StandardError
    attr_reader :feature, :attempts

    # attempts: [{ model:, error_class: }] in the order tried; never a provider body, a prompt or a key.
    def initialize(feature:, attempts:)
      @feature = feature.to_s
      @attempts = attempts.map(&:freeze).freeze
      tried = @attempts.map { |attempt| "#{attempt[:model]}=#{attempt[:error_class]}" }.join(', ')
      super("No decision model answered for #{@feature} (#{tried.presence || 'no model tried'}).")
    end
  end

  class << self
    # question: { state:, criteria: (key => description), instructions: } for one question, or { state:, questions: { name =>
    # { criteria:, instructions: } } } for several questions in one call. Options: observability:, timeout: seconds per model (the
    # feature's profile by default), total_timeout: seconds for the whole chain (timeout x models by default), models: the models to
    # ask instead of the platform chain (the evaluation harness only); any other keyword (assistant:, conversation:, session_id:
    # ...) goes to every Llm::FeatureRequest.
    def decide(feature:, account:, question:, **options)
      raise ArgumentError, 'Decisions is unavailable for this feature.' unless Llm::FeatureProfile.decision_feature?(feature)

      new(feature, account, question.to_h.symbolize_keys.slice(:state, :criteria, :instructions, :questions), options).call
    end

    # The chain of the feature (a JSON list or a comma-separated list of model ids in its installation config), cut to the
    # supported decision models; the built-in chain when the setting is blank, unreadable or names none of them.
    def models(feature = nil)
      chain = FEATURE_CHAINS[Llm::FeatureProfile.normalize_feature(feature)]
      default = chain ? chain[:default] : DEFAULT_MODELS
      supported(parse_models(InstallationConfig.find_by(name: chain ? chain[:config] : CONFIG_NAME)&.value)).presence || default
    rescue StandardError => e
      Rails.logger.warn("[LLM][DecisionChain] chain setting unreadable error_class=#{e.class.name}")
      default || DEFAULT_MODELS
    end

    def supported(names)
      names.map { |model| Llm::Models.canonical_model_name(model) }
           .select { |model| Llm::OpenRouterDecisionClient.supported_model?(model) }.uniq.first(MAX_MODELS)
    end

    private

    def parse_models(value)
      return value.map(&:to_s) if value.is_a?(Array)

      text = value.to_s.strip
      return [] if text.empty?
      return Array(JSON.parse(text)).map(&:to_s) if text.start_with?('[')

      text.split(/[\s,]+/).compact_blank
    rescue JSON::ParserError
      []
    end
  end

  def initialize(feature, account, question, options)
    @feature = feature
    @account = account
    @question = question
    # The chain sets the model, the question and the bound of every call itself.
    @request = options.except(:observability, :timeout, :total_timeout, :feature, :account, :model, :input, :options, :models)
    @observability = options[:observability].to_h
    @models = options[:models].present? ? self.class.supported(Array(options[:models])) : self.class.models(feature)
    @timeout = (options[:timeout] || Llm::FeatureProfile.for(feature, account: account).timeout_seconds).to_f
    @total_timeout = (options[:total_timeout] || (@timeout * @models.size)).to_f
  end

  def call
    deadline = monotonic_now + @total_timeout
    attempts = []
    @models.each_with_index do |model, index|
      remaining = deadline - monotonic_now
      break if remaining < MIN_ATTEMPT_SECONDS

      return attempt(model, index + 1, [@timeout, remaining].min)
    rescue StandardError => e
      attempts << { model: model, error_class: e.class.name }
      Rails.logger.warn("[LLM][DecisionChain] model failed feature=#{@feature} model=#{model} position=#{index + 1} error_class=#{e.class.name}")
    end
    raise ExhaustedError.new(feature: @feature, attempts: attempts)
  end

  private

  def attempt(model, position, timeout)
    response = Llm::Runtime.decide(
      feature: @feature, account: @account, model: model, input: @question[:state],
      options: question_options.merge(decision_timeout_seconds: timeout, decision_fallback: false),
      observability: @observability.merge(decision_chain_position: position, decision_chain_length: @models.size),
      **@request
    )
    Result.new(choice: response.choice, confidence: response.confidence, probabilities: response.probabilities.to_h,
               answers: response.respond_to?(:answers) ? response.answers.to_h : {}, model: model, served_model: response.model,
               position: position)
  end

  def question_options
    return { decision_questions: @question[:questions] } if @question[:questions].present?

    { decision_criteria: @question[:criteria], decision_instructions: @question[:instructions] }
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
