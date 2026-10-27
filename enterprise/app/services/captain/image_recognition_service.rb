# The text of a customer's image, made once and kept in the meta of the attachment. The reading itself is Captain::ImageReading::Reader:
# a router looks at the image, then one of two platform models reads it (see there). This service is the cache and the rule that one
# call at a time describes an image.
class Captain::ImageRecognitionService < Llm::BaseAiService
  CACHE_KEY = 'image_recognition_description'.freeze
  # Which reader made the description (:ordinary or :handwriting, as a string) and which model, kept next to the text.
  READER_KEY = 'image_recognition_reader'.freeze
  MODEL_KEY = 'image_recognition_model'.freeze
  FALLBACK_DESCRIPTION = 'User shared an image, but image recognition is temporarily unavailable.'.freeze
  # One call at a time describes an image (see #describe_once): the description made when the image arrived (Messages::ImageDescriptionJob)
  # and the one a reply suggestion or an agent run asks for are never two paid calls.
  LOCK_PREFIX = 'captain:image_description'.freeze
  # Longer than a reading takes at its slowest: the load, the router, a reasoning reader (about 14 s) and a retry of the provider.
  LOCK_TTL_SECONDS = 90
  # How long a caller waits for the call another process is making: about the time of a slow reading, so a stuck holder costs the
  # waiter little more than describing the image itself would.
  WAIT_SECONDS = 25
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
    # The class and the message of the error: the message of a fetch or a decode names no URL and no content.
    Rails.logger.warn(
      'Skipping image recognition: ' \
      "attachment_id=#{attachment&.id} account_id=#{account&.id} error=#{e.class}: #{e.message}"
    )
    FALLBACK_DESCRIPTION
  end

  # `model` (Llm::BaseAiService) is the model of an ordinary image (CAPTAIN_IMAGE_RECOGNITION_MODEL); this is the model of an image
  # with significant handwriting (CAPTAIN_IMAGE_HANDWRITING_MODEL).
  def handwriting_model
    @handwriting_model ||= Llm::Config.model_for(feature: 'image_handwriting', account: account, fallback: nil)
  end

  private

  def recognize
    reading = Captain::ImageReading::Reader.new(
      account: account, attachment: attachment, image_url: image_url,
      models: { ordinary: model, handwriting: handwriting_model }
    ).read
    return FALLBACK_DESCRIPTION if reading.description.blank?

    cache_reading(reading)
    reading.description
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

  # The cache as the database has it now (the attachment in memory may be older than a description made meanwhile). Never through the
  # query cache: a job runs inside the Rails executor, which switches it on, and it would give a waiter the blank it read first for as
  # long as the job lasts, whatever the other process has written since. The waiter would then describe the image a second time.
  def fresh_description
    meta = Attachment.uncached { Attachment.where(id: attachment.id).pick(:meta) }
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

  def cached_description
    attachment&.meta.to_h[CACHE_KEY].to_s.strip.presence
  end

  def cache_reading(reading)
    return if attachment.blank? || reading.description.blank? || reading.description == FALLBACK_DESCRIPTION

    attachment.update!(
      meta: attachment.meta.to_h.merge(
        CACHE_KEY => reading.description, READER_KEY => reading.reader.to_s, MODEL_KEY => reading.model
      )
    )
  end
end
