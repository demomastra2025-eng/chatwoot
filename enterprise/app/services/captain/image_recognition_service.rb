class Captain::ImageRecognitionService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  CACHE_KEY = 'image_recognition_description'.freeze
  FALLBACK_DESCRIPTION = 'User shared an image, but image recognition is temporarily unavailable.'.freeze
  # One call at a time describes an image (see #describe_once): the description made when the image arrived (Messages::ImageDescriptionJob)
  # and the one a reply suggestion or an agent run asks for are never two paid calls.
  LOCK_PREFIX = 'captain:image_description'.freeze
  LOCK_TTL_SECONDS = 60
  # How long a caller waits for the call another process is making: about the time of a call, so a stuck holder costs the waiter
  # little more than describing the image itself would.
  WAIT_SECONDS = 15
  POLL_SECONDS = 0.25

  attr_reader :account, :attachment, :image_url

  def initialize(account:, image_url:, attachment: nil)
    @account = account
    @attachment = attachment
    @image_url = image_url
    super()
  end

  def perform
    return cached_description if cached_description.present?
    return FALLBACK_DESCRIPTION if image_url.blank? || model.blank?

    describe_once
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

  def recognize
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
  end

  # An image is described by one call at a time. A caller that finds another one describing it (the job that runs when the image
  # arrives, a reply suggestion, a live run) waits for that description in the cache of the attachment instead of paying for a
  # second call; it describes the image itself when the other call ends without one, or is not done within WAIT_SECONDS.
  def describe_once
    return recognize if attachment.blank?

    lock = Redis::LockManager.new
    deadline = monotonic_now + WAIT_SECONDS
    loop do
      return describe_holding(lock) if lock_taken?(lock)

      description = wait_for_holder(deadline)
      return description if description.present?
      return recognize if monotonic_now >= deadline
    end
  end

  def describe_holding(lock)
    # The holder before us may have finished between our look at the cache and the lock.
    fresh_description || recognize
  ensure
    release_lock(lock)
  end

  # true: this call describes the image (also without a lock when Redis fails: the lock only saves a call, it never blocks one).
  def lock_taken?(lock)
    lock.lock(lock_key, LOCK_TTL_SECONDS) || false
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ImageDescription] lock unavailable attachment_id=#{attachment.id} error_class=#{e.class.name}")
    true
  end

  def release_lock(lock)
    lock.unlock(lock_key)
  rescue StandardError
    nil
  end

  # The description another call has made, or nil: the other call ended without one, or the deadline came.
  def wait_for_holder(deadline)
    while monotonic_now < deadline
      description = fresh_description
      return description if description.present?
      return unless Redis::Alfred.exists?(lock_key)

      sleep POLL_SECONDS
    end
    nil
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ImageDescription] wait failed attachment_id=#{attachment.id} error_class=#{e.class.name}")
    sleep POLL_SECONDS
    nil
  end

  # The cache as the database has it now (the attachment in memory may be older than a description made meanwhile).
  def fresh_description
    meta = Attachment.where(id: attachment.id).pick(:meta)
    meta.to_h[CACHE_KEY].to_s.strip.presence
  end

  def lock_key
    "#{LOCK_PREFIX}:#{attachment.id}"
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

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
    attachment&.meta.to_h[CACHE_KEY].to_s.strip.presence
  end

  def cache_description(description)
    return if attachment.blank? || description.blank? || description == FALLBACK_DESCRIPTION

    attachment.update!(meta: attachment.meta.to_h.merge(CACHE_KEY => description))
  end
end
