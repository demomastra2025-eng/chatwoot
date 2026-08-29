class Captain::ImageRecognitionService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  CACHE_KEY = 'image_recognition_description'.freeze
  FALLBACK_DESCRIPTION = 'User shared an image, but image recognition is temporarily unavailable.'.freeze

  attr_reader :account, :attachment, :image_url

  def self.cached_description(attachment)
    attachment&.meta.to_h[CACHE_KEY].to_s.strip.presence
  end

  def initialize(account:, image_url:, attachment: nil)
    @account = account
    @attachment = attachment
    @image_url = image_url
    super()
  end

  def perform
    return cached_description if cached_description.present?
    return FALLBACK_DESCRIPTION if image_url.blank? || model.blank?

    response = instrument_image_recognition(instrumentation_params) do
      Llm::Runtime.chat(
        feature: :image_recognition,
        account: account,
        model: model,
        messages: [
          {
            role: 'user',
            content: RubyLLM::Content.new(recognition_prompt, [image_url])
          }
        ],
        observability: instrumentation_params.merge(runtime_mode: 'image_recognition'),
        options: { temperature: 0 }
      )
    end

    description = response.respond_to?(:content) ? response.content.to_s.strip : response.to_s.strip
    description = description.presence || FALLBACK_DESCRIPTION
    cache_description(description)
    description
  rescue RubyLLM::UnauthorizedError, Faraday::UnauthorizedError => e
    Rails.logger.warn("Skipping image recognition: LLM provider configuration is invalid or disabled (#{e.class}).")
    FALLBACK_DESCRIPTION
  rescue StandardError => e
    Rails.logger.warn(
      'Skipping image recognition: ' \
      "attachment_id=#{attachment&.id} account_id=#{account&.id} error=#{e.class}: #{e.message}"
    )
    FALLBACK_DESCRIPTION
  end

  private

  def llm_feature_key
    'image_recognition'
  end

  def llm_model_account
    account
  end

  def instrumentation_params
    {
      span_name: 'llm.captain.image_recognition',
      model: model,
      provider: Llm::Config.provider_for_model(model, account: account),
      account_id: account&.id,
      feature_name: 'image_recognition',
      attachment_id: attachment&.id,
      image_url: image_url
    }
  end

  def instrument_image_recognition(observability, &)
    instrument_llm_call(observability, &)
  end

  def recognition_prompt
    <<~PROMPT.squish
      Describe the attached customer-shared image for a support AI agent.
      Return concise factual text only. Include visible text, product names, order numbers,
      error messages, UI states, documents, receipts, damages, or screenshots if present.
      Do not guess hidden facts. If the image is unclear, say what is unclear.
    PROMPT
  end

  def cached_description
    self.class.cached_description(attachment)
  end

  def cache_description(description)
    return if attachment.blank? || description.blank? || description == FALLBACK_DESCRIPTION

    attachment.update!(meta: attachment.meta.to_h.merge(CACHE_KEY => description))
  end
end
