# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'timeout'
require_relative 'egress_guard'

# The native OpenRouter Decisions endpoint (/alpha/decisions). One call asks one question (criteria:, instructions:, sent as the
# question "reason") or several questions at once (questions: { name => { criteria:, instructions: } }), and the model answers
# every question with one of its criteria. Only bounded metadata comes back: the chosen keys, their confidence and probabilities,
# the served model, the provider, the generation id and the usage; never prose, never the request.
class Llm::OpenRouterDecisionClient
  SUPPORTED_MODELS = %w[
    inception/mercury-decide microsoft/microsoft-decision-1 microsoft/microsoft-decision-1-20261009
    openai/gpt-6-luna-decisions
    perplexity/pplx-decider-v1.2 perplexity/pplx-decider-flash-v1.2 typesafe/jev-1.14 liquid/d1-ultra respan/span-02
    nace-ai/drex-max
  ].freeze
  NON_ZDR_MODELS = %w[openai/gpt-6-luna-decisions respan/span-02].freeze
  DEFAULT_API_BASE = 'https://openrouter.ai/api/v1'
  REQUEST_TIMEOUT_SECONDS = 110
  MAX_RESPONSE_BYTES = 1_048_576
  MAX_REQUEST_BYTES = 131_072
  # A call whose state carries an image (Llm::FeatureProfile#max_request_bytes) may ask for a larger body, up to this bound.
  MAX_IMAGE_REQUEST_BYTES = 2_097_152
  SINGLE_QUESTION = 'reason'
  MAX_QUESTIONS = 16
  QUESTION_NAME = /\A[a-zA-Z0-9_-]{1,64}\z/
  CRITERION_KEY = /\A[a-zA-Z0-9_-]{1,100}\z/

  Answer = Struct.new(:choice, :confidence, :probabilities, keyword_init: true)
  # choice / confidence / probabilities: the answer of a single question. For several questions, answers holds one Answer per
  # question; choice is then a summary of the chosen keys ("name=key ...", for the logs) and confidence the lowest confidence.
  Result = Struct.new(:choice, :confidence, :probabilities, :answers, :model, :provider, :request_id, :usage, keyword_init: true)

  class Error < StandardError; end

  class << self
    def supported_model?(model)
      SUPPORTED_MODELS.include?(model)
    end

    def zdr_supported_model?(model)
      supported_model?(model) && NON_ZDR_MODELS.exclude?(model.to_s)
    end

    # One question: criteria: + instructions:. Several questions: questions: { name => { criteria:, instructions: } }.
    def choose(state:, criteria: nil, instructions: nil, questions: nil, **options)
      questions = normalized_questions(criteria, instructions, questions)
      validate_request!(state, questions, options)
      uri = decision_uri(options[:api_base])
      request = build_request(uri, state, questions, options)
      code, body = perform_request(uri, request, options[:timeout] || REQUEST_TIMEOUT_SECONDS)
      raise Error, "OpenRouter decision request failed (HTTP #{code})." unless code.between?(200, 299)

      parse_response(body, questions)
    rescue JSON::ParserError
      raise Error, 'OpenRouter decision returned invalid JSON.'
    rescue Timeout::Error, OpenSSL::SSL::SSLError, EOFError, SocketError, SystemCallError, Net::HTTPBadResponse
      # Do not propagate provider bodies, request data, URLs or credentials into logs.
      raise Error, 'OpenRouter decision transport unavailable.'
    end

    private

    def normalized_questions(criteria, instructions, questions)
      return { SINGLE_QUESTION => { criteria: criteria, instructions: instructions } } if questions.nil?
      raise ArgumentError, 'Invalid decision questions.' unless questions.is_a?(Hash) && criteria.nil? && instructions.nil?

      questions.to_h do |name, question|
        question = question.to_h.with_indifferent_access
        [name.to_s, { criteria: question[:criteria], instructions: question[:instructions] }]
      end
    end

    def validate_request!(state, questions, options)
      raise ArgumentError, 'Unsupported decision model.' unless supported_model?(options[:model])
      raise ArgumentError, 'OpenRouter decision key is required.' unless options[:api_key].is_a?(String) && options[:api_key].present?

      validate_state_and_bounds!(state, options)
      validate_questions!(questions)
    end

    # The state is an object, or a list of parts when it carries an image; the timeout and the request limit are bounded.
    def validate_state_and_bounds!(state, options)
      raise ArgumentError, 'Invalid decision state.' unless state.is_a?(Hash) || state.is_a?(Array)
      raise ArgumentError, 'Invalid decision timeout.' unless valid_timeout?(options[:timeout])
      raise ArgumentError, 'Invalid decision request limit.' unless valid_request_limit?(options[:max_request_bytes])
    end

    def validate_questions!(questions)
      raise ArgumentError, 'Invalid decision questions.' unless questions.size.between?(1, MAX_QUESTIONS)

      questions.each do |name, question|
        raise ArgumentError, 'Invalid decision questions.' unless name.match?(QUESTION_NAME)

        validate_question!(question)
      end
    end

    def validate_question!(question)
      instructions = question[:instructions]
      raise ArgumentError, 'Invalid decision instructions.' unless instructions.is_a?(String) && instructions.length.between?(1, 8000)
      raise ArgumentError, 'Invalid decision choices.' unless valid_criteria?(question[:criteria])
    end

    def valid_criteria?(criteria)
      criteria.is_a?(Hash) && criteria.size.between?(2, 64) && criteria.all? { |key, value| valid_criterion?(key, value) }
    end

    def valid_criterion?(key, value)
      key.is_a?(String) && key.match?(CRITERION_KEY) && value.is_a?(String) && value.length.between?(1, 2000)
    end

    def valid_timeout?(timeout)
      timeout.nil? || (timeout.is_a?(Numeric) && timeout.finite? && timeout.positive? && timeout <= REQUEST_TIMEOUT_SECONDS)
    end

    def valid_request_limit?(limit)
      limit.nil? || (limit.is_a?(Integer) && limit.between?(MAX_REQUEST_BYTES, MAX_IMAGE_REQUEST_BYTES))
    end

    # The Decisions endpoint rejects `"provider": null` (HTTP 400), so a blank preference is left out of the body.
    def build_request(uri, state, questions, options)
      redacted_state = Llm::OutboundIinRedactor.redact_payload(state)
      redacted_questions = Llm::OutboundIinRedactor.redact_iin_only(question_bodies(questions))
      body = JSON.generate({ model: options[:model], state: redacted_state, questions: redacted_questions,
                             provider: options[:provider].presence }.compact)
      raise ArgumentError, 'Decision request too large.' if body.bytesize > (options[:max_request_bytes] || MAX_REQUEST_BYTES)

      Net::HTTP::Post.new(uri).tap do |request|
        request['Authorization'] = "Bearer #{options[:api_key]}"
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        Llm::OpenRouterHeaders.apply!(request, headers: options[:headers])
        request.body = body
      end
    end

    def question_bodies(questions)
      questions.transform_values do |question|
        { type: 'choice', instructions: question[:instructions], criteria: question[:criteria] }
      end
    end

    # Two sequential calls (short fragment, optional expansion) stay below the 300s job lease. A caller inside a patient turn
    # passes a short timeout, which bounds the whole call and each socket wait.
    def perform_request(uri, request, timeout)
      Timeout.timeout(timeout) do
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: [10, timeout].min, read_timeout: [90, timeout].min,
                                                write_timeout: [10, timeout].min) do |http|
          http.max_retries = 0
          Llm::EgressGuard.check!
          http.request(request) do |response|
            body = +''
            response.read_body do |chunk|
              body << chunk
              raise Error, 'OpenRouter decision response too large.' if body.bytesize > MAX_RESPONSE_BYTES
            end
            return [response.code.to_i, body]
          end
        end
      end
    end

    def parse_response(body, questions)
      data = JSON.parse(body)
      answers = data.is_a?(Hash) && data['answers'].is_a?(Hash) ? data['answers'] : nil
      unless answers && data['model'].is_a?(String) && data['model'].length.between?(1, 200)
        raise Error, 'OpenRouter decision returned an invalid selection.'
      end

      parsed = questions.to_h { |name, question| [name, parse_answer(answers[name], question[:criteria])] }
      result_for(parsed, data)
    end

    def parse_answer(answer, criteria)
      raise Error, 'OpenRouter decision returned an invalid selection.' unless answer.is_a?(Hash) && criteria.key?(answer['choice'])

      confidence = answer['confidence']
      if !confidence.nil? && (!confidence.is_a?(Numeric) || !confidence.finite? || !confidence.between?(0, 1))
        raise Error, 'OpenRouter decision returned invalid confidence.'
      end

      Answer.new(choice: answer['choice'], confidence: confidence, probabilities: safe_probabilities(answer['probabilities'], criteria))
    end

    def result_for(answers, data)
      single = answers.keys == [SINGLE_QUESTION] ? answers[SINGLE_QUESTION] : nil
      Result.new(choice: single ? single.choice : answers.map { |name, answer| "#{name}=#{answer.choice}" }.join(' '),
                 confidence: single ? single.confidence : lowest_confidence(answers.values),
                 probabilities: single ? single.probabilities : {}, answers: answers,
                 model: data['model'], provider: safe_identifier(data['provider']), request_id: safe_identifier(data['id']),
                 usage: safe_usage(data['usage']))
    end

    # The confidence of several answers together: the lowest one; none when any answer has none.
    def lowest_confidence(answers)
      values = answers.map(&:confidence)
      values.all?(Numeric) ? values.min : nil
    end

    # Only the probabilities of the offered choices, each a number between 0 and 1; anything else is dropped.
    def safe_probabilities(value, criteria)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, number), result|
        next unless criteria.key?(key) && number.is_a?(Numeric) && number.finite? && number.between?(0, 1)

        result[key] = number
      end
    end

    def safe_usage(value)
      return {} unless value.is_a?(Hash)

      value.slice('input_tokens', 'output_tokens', 'total_tokens', 'cost').select do |_key, number|
        number.is_a?(Numeric) && number.finite? && number >= 0
      end
    end

    def safe_identifier(value)
      value if value.is_a?(String) && value.length.between?(1, 256) && !value.match?(/[\r\n]/)
    end

    def decision_uri(api_base)
      uri = URI(api_base.presence || DEFAULT_API_BASE)
      unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise ArgumentError, 'Invalid OpenRouter decision endpoint.'
      end

      base_path = uri.path.chomp('/').delete_suffix('/chat/completions').delete_suffix('/models')
      uri.path = case base_path
                 when %r{/alpha/decisions\z} then base_path
                 when %r{/v1\z} then "#{base_path.delete_suffix('/v1')}/alpha/decisions"
                 when %r{/api\z} then "#{base_path}/alpha/decisions"
                 else raise ArgumentError, 'Unsupported OpenRouter decision endpoint.'
                 end
      uri
    rescue URI::InvalidURIError
      raise ArgumentError, 'Invalid OpenRouter decision endpoint.'
    end
  end
end
