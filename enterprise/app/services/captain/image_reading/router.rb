# frozen_string_literal: true

# Looks at a customer's image once, before it is read, and says which reader it needs: a decision model answers one question, does the
# image hold significant handwriting. P(handwriting) at or above THRESHOLD, or no answer at all, means the handwriting reader (the
# safe one: it does not invent words on a hand, which the cheap reader does); anything else is read by the ordinary reader.
# One rule, no chain: the router never asks a second model, and it never raises.
#
# Benchmark 27.10, 81 images, nine decision models: perplexity/pplx-decider-v1.2 had the fewest false alarms, at a threshold of 0.3 it
# kept every hard image, about 0.5 s and $0.02 per 1000 images.
class Captain::ImageReading::Router
  QUESTION_CRITERIA = {
    'handwriting' => 'The image holds significant handwriting: a handwritten note, letter, list, or a form filled in by hand.',
    'no_handwriting' => 'No significant handwriting: printed text, a screenshot, a receipt, a photo, or another image without ' \
                        'handwritten text that matters.'
  }.freeze
  QUESTION = 'Does this image hold significant handwritten text that matters? Pick exactly one.'
  STATE_TEXT = 'An image a customer sent to the chat of a company.'
  HANDWRITING = 'handwriting'
  THRESHOLD = 0.3

  # reader: :handwriting or :ordinary. status: 'ok' or 'failed' (then reader is :handwriting). probability: P(handwriting), nil when the
  # answer carried none. cost: what the call cost in dollars when the provider said so.
  Decision = Struct.new(:reader, :status, :choice, :probability, :model, :latency_ms, :cost, :error_class, keyword_init: true) do
    def handwriting? = reader == :handwriting
    def failed? = status == 'failed'
  end

  def initialize(account:, picture:, observability: {})
    @account = account
    @picture = picture
    @observability = observability
  end

  def decide
    started = monotonic_now
    result = Llm::Runtime.decide(
      feature: :image_routing, account: @account, input: state, observability: @observability,
      options: { decision_criteria: QUESTION_CRITERIA, decision_instructions: QUESTION, decision_fallback: false }
    )
    answered(result, latency_ms(started))
  rescue StandardError => e
    # The error class only: never the request, a URL or a provider body.
    Rails.logger.warn("[CAPTAIN][ImageRouter] failed account_id=#{@account&.id} error_class=#{e.class.name}")
    Decision.new(reader: :handwriting, status: 'failed', latency_ms: latency_ms(started), error_class: e.class.name)
  end

  private

  def state
    [STATE_TEXT, { type: 'image_url', image_url: { url: @picture.for_router.data_url } }]
  end

  def answered(result, latency)
    probability = handwriting_probability(result)
    handwriting = probability.nil? ? result.choice == HANDWRITING : probability >= THRESHOLD
    Decision.new(
      reader: handwriting ? :handwriting : :ordinary, status: 'ok', choice: result.choice, probability: probability,
      model: result.model, latency_ms: latency, cost: usage_cost(result)
    )
  end

  # P(handwriting) from the probabilities of the answer, else from the confidence of the choice, else nil.
  def handwriting_probability(result)
    value = result.probabilities.to_h[HANDWRITING]
    return value.to_f if value.is_a?(Numeric)

    confidence = result.confidence
    return unless confidence.is_a?(Numeric)

    result.choice == HANDWRITING ? confidence.to_f : 1.0 - confidence.to_f
  end

  def usage_cost(result)
    cost = result.usage.to_h['cost']
    cost.to_f if cost.is_a?(Numeric)
  end

  def latency_ms(started)
    started ? ((monotonic_now - started) * 1000).round : nil
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
