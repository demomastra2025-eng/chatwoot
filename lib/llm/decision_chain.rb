# frozen_string_literal: true

# One decision inside a patient turn, asked down the platform chain of decision models: the first model that answers in
# time wins; a model that fails, times out or answers outside the criteria passes the same question to the next one.
# Every call is an ordinary Llm::Runtime.decide (budgets, headers, one llm.decision.complete event each, marked with its
# position in the chain). When no model answers, ExhaustedError is raised: the caller ends the turn through its
# technical-failure path, the same as when OpenRouter is down for generation.
class Llm::DecisionChain
  CONFIG_NAME = 'CAPTAIN_DECISION_MODEL_CHAIN'
  DEFAULT_MODELS = %w[inception/mercury-decide microsoft/microsoft-decision-1 openai/gpt-6-luna-decisions].freeze
  MAX_MODELS = 3
  # Below this a call cannot finish, so the chain stops instead of starting it.
  MIN_ATTEMPT_SECONDS = 0.3

  # model: the model of the chain that answered; served_model: the dated model OpenRouter actually ran; position: 1 for the head.
  Result = Struct.new(:choice, :confidence, :probabilities, :model, :served_model, :position, keyword_init: true) do
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
    # question: { state:, criteria: (key => description), instructions: } as for Llm::Runtime.decide. Options: observability:,
    # timeout: seconds per model (the feature's profile by default), total_timeout: seconds for the whole chain (timeout x
    # models by default); any other keyword (assistant:, conversation:, session_id: ...) goes to every Llm::FeatureRequest.
    def decide(feature:, account:, question:, **options)
      raise ArgumentError, 'Decisions is unavailable for this feature.' unless Llm::FeatureProfile.decision_feature?(feature)

      new(feature, account, question.to_h.symbolize_keys.slice(:state, :criteria, :instructions), options).call
    end

    # The platform chain (installation config CAPTAIN_DECISION_MODEL_CHAIN: a JSON list or a comma-separated list of model ids),
    # cut to the supported decision models; the built-in chain when the setting is blank, unreadable or names none of them.
    def models
      configured = parse_models(InstallationConfig.find_by(name: CONFIG_NAME)&.value)
      configured = configured.map { |model| Llm::Models.canonical_model_name(model) }
                             .select { |model| Llm::OpenRouterDecisionClient.supported_model?(model) }.uniq.first(MAX_MODELS)
      configured.presence || DEFAULT_MODELS
    rescue StandardError => e
      Rails.logger.warn("[LLM][DecisionChain] chain setting unreadable error_class=#{e.class.name}")
      DEFAULT_MODELS
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
    @request = options.except(:observability, :timeout, :total_timeout, :feature, :account, :model, :input, :options)
    @observability = options[:observability].to_h
    @models = self.class.models
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
      options: { decision_criteria: @question[:criteria], decision_instructions: @question[:instructions],
                 decision_timeout_seconds: timeout },
      observability: @observability.merge(decision_chain_position: position, decision_chain_length: @models.size),
      **@request
    )
    Result.new(choice: response.choice, confidence: response.confidence, probabilities: response.probabilities.to_h,
               model: model, served_model: response.model, position: position)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
