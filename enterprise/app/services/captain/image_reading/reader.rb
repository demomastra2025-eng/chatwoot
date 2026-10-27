# frozen_string_literal: true

# Reads a customer's image into text, once: the image is loaded (and resized only when its long side is above 1536 px), the router
# says whether it holds significant handwriting, and the reader chosen by that answer transcribes it. Both models receive the image
# as data inside the request. The reader is one of two platform models, the same for every account (CAPTAIN_IMAGE_RECOGNITION_MODEL
# for an ordinary image, CAPTAIN_IMAGE_HANDWRITING_MODEL for handwriting); there is no fallback model.
#
# One llm_events row per reading (captain.image.read): the router decision, its probability, the reader, the latency of both and what
# they cost; never the image, a link to it or the text read from it. The row carries the tokens and the costs in its payload only,
# never in the columns the dashboards add up (prompt_tokens, estimated_cost; the tokens are one nested hash, because the log redacts
# a key with «token» in its name): the calls themselves (llm.decision.complete and
# llm.chat.complete) are already counted there, and a second count of the same dollars would double the spend of the images.
class Captain::ImageReading::Reader
  include Integrations::LlmInstrumentation

  EVENT = 'captain.image.read'
  # A reasoning reader spends part of its output on thinking before it writes the text (Terra), so the limit leaves room for both.
  MAX_OUTPUT_TOKENS = 2500
  ZERO_TEMPERATURE = 0

  Reading = Struct.new(:description, :reader, :model, keyword_init: true)

  class NoReaderModel < StandardError; end

  # models: { ordinary: model id, handwriting: model id } resolved by the caller from the platform settings.
  def initialize(account:, attachment:, image_url:, models:)
    @account = account
    @attachment = attachment
    @image_url = image_url
    @models = models
  end

  # A Reading with the text of the image. Raises when the image cannot be loaded or the reader fails; the event of the reading
  # records the failure.
  def read
    Llm::EventBus.publish(EVENT, base_payload) do |event|
      run(event)
    rescue StandardError => e
      Llm::ObservabilityPayload.attach_error!(event, e)
      raise
    end
  end

  private

  def run(event)
    picture = Captain::ImageReading::Picture.load(attachment: @attachment, url: @image_url)
    decision = route(picture)
    # The decision is on the record also when the reader fails after it.
    event.merge!(router_fields(decision))
    model = @models[decision.reader]
    raise NoReaderModel, "no model for the #{decision.reader} reader" if model.blank?

    started = monotonic_now
    response = request_reading(picture, model)
    event.merge!(reader_fields(decision, model, response, latency_ms(started)))
    Reading.new(description: text_of(response).presence, reader: decision.reader, model: model)
  end

  def route(picture)
    Captain::ImageReading::Router.new(
      account: @account, picture: picture, observability: observability.merge(feature_name: 'image_routing')
    ).decide
  end

  def text_of(response)
    response.respond_to?(:content) ? response.content.to_s.strip : response.to_s.strip
  end

  def request_reading(picture, model)
    content = RubyLLM::Content.new(Captain::ImageReading::Prompt.read(@account))
    image = picture.for_reader
    content.add_attachment(image.io, filename: image.filename)
    instrument_llm_call(instrumentation_params(model)) do
      Llm::Runtime.chat(
        feature: :image_recognition, account: @account, model: model, max_tokens: MAX_OUTPUT_TOKENS,
        messages: [{ role: 'user', content: content }],
        observability: observability.merge(runtime_mode: 'image_recognition'),
        options: reader_options(model)
      )
    end
  end

  # Reading is transcription, not writing: no temperature where the model does not take one (Terra rejects it).
  def reader_options(model)
    Llm::ModelParameters.for(model, account: @account).compile(temperature: ZERO_TEMPERATURE)
  end

  def base_payload
    { feature: 'image_recognition', runtime_mode: 'image_recognition', account_id: @account&.id, attachment_id: @attachment&.id,
      status: 'success', error: false }
  end

  def router_fields(decision)
    {
      'reader' => decision.reader.to_s, 'router_status' => decision.status, 'router_model' => decision.model,
      'router_choice' => decision.choice, 'router_probability' => decision.probability&.round(4), 'router_ms' => decision.latency_ms,
      'router_cost' => decision.cost, 'router_error_class' => decision.error_class
    }.compact
  end

  def reader_fields(decision, model, response, reader_ms)
    input = token_count(response, :input_tokens)
    output = token_count(response, :output_tokens)
    cost = reader_cost(model, input, output)
    {
      'model' => model, 'reader_ms' => reader_ms, 'reader_usage' => { 'input_tokens' => input, 'output_tokens' => output }.compact.presence,
      'reader_cost' => cost, 'total_cost' => total_cost(decision.cost, cost)
    }.compact
  end

  # An estimate from the price of the model in the catalog; nil while the catalog has no price for it.
  def reader_cost(model, input, output)
    return if input.nil? && output.nil?

    Llm::Models.estimated_text_cost(model, input_tokens: input.to_i, output_tokens: output.to_i)&.to_f
  rescue StandardError
    nil
  end

  def total_cost(router_cost, reader_cost)
    return if router_cost.nil? && reader_cost.nil?

    (router_cost.to_f + reader_cost.to_f).round(8)
  end

  def token_count(response, name)
    response.respond_to?(name) ? response.public_send(name) : nil
  end

  # The account and the attachment only: no image, no link to it.
  def observability
    { account_id: @account&.id, feature_name: 'image_recognition', attachment_id: @attachment&.id }.compact
  end

  def instrumentation_params(model)
    observability.merge(
      span_name: 'llm.captain.image_recognition', model: model, provider: Llm::Config.provider_for_model(model, account: @account)
    )
  end

  def latency_ms(started)
    ((monotonic_now - started) * 1000).round
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
