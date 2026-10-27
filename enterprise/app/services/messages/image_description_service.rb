# frozen_string_literal: true

# The description of an image that has just arrived in a conversation of an AI agent (see Enterprise::Concerns::Attachment), made in
# the background so that nobody waits for the vision model later: the agent of a reply suggestion or of a live reply finds the
# description in the cache of the attachment (Captain::ImageRecognitionService::CACHE_KEY). PROD 27.10: one fresh image took 11.7 s of
# a 35 s reply suggestion.
#
# It is the same description of the same image as the one a run makes itself: Captain::OpenAiMessageBuilderService decides which
# images are described and from which URL, and Captain::ImageRecognitionService makes the call, one call at a time per image. An image
# that is not described yet when a run needs it is described by the run, as before.
#
# Only the images the agent can see are described: a conversation of an inbox with an agent, an account with AI and image
# understanding on. Never an image of the imported history or of an old message: nobody is waiting for it.
class Messages::ImageDescriptionService
  # CAPTAIN_IMAGE_DESCRIPTION_ON_ARRIVAL=off describes images only when a run asks for them, as before.
  SWITCH = 'CAPTAIN_IMAGE_DESCRIPTION_ON_ARRIVAL'
  OFF_VALUES = %w[off 0 false disabled no].freeze
  MAX_MESSAGE_AGE = 6.hours
  MESSAGE_TYPES = %w[incoming outgoing].freeze

  # The file of the image is not attached yet (some channels attach it after the message is saved), or is attached but its bytes are not
  # in the storage yet (the record is saved before its upload ends).
  class NotReady < StandardError; end

  class << self
    # No network: this runs when the attachment is created, and again when the job starts.
    def enabled_for?(attachment)
      return false unless attachment&.image? && switched_on?

      message = attachment.message
      describable_message?(message) && agent_inbox?(message.inbox) && ai_images_enabled?(message.account)
    end

    private

    def switched_on?
      OFF_VALUES.exclude?(ENV.fetch(SWITCH, nil).to_s.strip.downcase)
    end

    def describable_message?(message)
      return false if message.blank? || message.private? || MESSAGE_TYPES.exclude?(message.message_type.to_s)
      return false if imported_history?(message)

      message.created_at.present? && message.created_at > MAX_MESSAGE_AGE.ago
    end

    def imported_history?(message)
      attributes = message.content_attributes
      attributes.respond_to?(:to_h) && ActiveModel::Type::Boolean.new.cast(attributes.to_h['imported_history']) == true
    end

    def ai_images_enabled?(account)
      account.present? && account.feature_enabled?('captain_integration') &&
        Captain::AccountSettings.new(account).section('understanding')['images'] && account.captain_quota_available?
    end

    # A text channel of a workspace with at least one enabled agent: the AI may read what the patient sends there.
    def agent_inbox?(inbox)
      inbox.present? && inbox.channel_type != CaptainInbox::VOICE_CHANNEL_TYPE && inbox.account.captain_assistants.entry_eligible.exists?
    end
  end

  attr_reader :attachment

  def initialize(attachment)
    @attachment = attachment
  end

  # Raises NotReady while the file is not attached, so that the job tries again a little later.
  def perform
    return unless self.class.enabled_for?(attachment)

    url = image_url
    return if url.blank?
    raise NotReady, "image attachment #{attachment.id} is not in the storage yet" unless stored?

    Captain::ImageRecognitionService.new(account: attachment.message.account, attachment: attachment, image_url: url).perform
  end

  private

  def image_url
    builder = Captain::OpenAiMessageBuilderService.new(message: attachment.message)
    target = builder.describable_images.find { |image, _url| image.id == attachment.id }
    return target.last if target

    raise NotReady, "image attachment #{attachment.id} has no file yet" if awaiting_file?
  end

  # The reading would fail on a file that is not in the storage yet, and the failure would be written down against the image: wait for it.
  def stored?
    blob = attachment.file.blob if attachment.file.attached?
    blob.nil? || blob.service.exist?(blob.key)
  end

  def awaiting_file?
    attachment.reload
    !attachment.file_purged? && !attachment.file.attached? && attachment.external_url.blank?
  end
end
