class Captain::OpenAiMessageBuilderService
  # What the model reads for a message with no text, no readable attachment and no transcript.
  EMPTY_CONTENT = 'Message without content'.freeze
  META_AD_REFERRAL_CONTEXT_FIELDS = [
    ['channel', [:provider]],
    ['attribution', %i[attribution_type attributionType]],
    ['source', [:source]],
    ['source type', %i[source_type sourceType]],
    ['headline', [:headline]],
    ['ad text', [:body]],
    ['media type', %i[media_type mediaType]],
    ['source URL', %i[source_url sourceUrl]],
    ['ad id', %i[ad_id adId]],
    ['source id', %i[source_id sourceId]],
    ['post id', %i[post_id postId]],
    ['product id', %i[product_id productId]],
    ['flow id', %i[flow_id flowId]],
    ['ref', [:ref]],
    ['referral type', %i[referral_type referralType]],
    ['received at', %i[received_at receivedAt]]
  ].freeze

  # The agent never receives an image, neither its pixels nor a link to it: only the text of the image, made by a program and said to
  # be possibly inaccurate (Captain::ImageReading::Prompt.agent_text). A link in the prompt cost a provider a fetch at every step of a
  # run (about 4 s each on PROD 27.10), and the library that builds the prompt downloaded the image only to learn its type.
  #
  # image_descriptions: { attachment_id => description }, made beforehand (see Captain::ReplySuggestion::ImageDescriber): every image
  # is then described from that map, never by a call made here. Without it the description kept on the attachment is used, and an
  # image that has none yet is described once now (Captain::ImageRecognitionService); the history budget limits how many images a
  # run may describe by a new call, and a description that already exists costs nothing.
  def initialize(message:, budget: nil, image_descriptions: nil)
    @message = message
    @budget = budget
    @image_descriptions = image_descriptions
  end

  # Extracts text and image URLs from multimodal content array (reverse of generate_content)
  def self.extract_text_and_attachments(content)
    Llm::MessageFormat.extract_text_and_attachments(content)
  end

  def generate_content
    parts = []
    primary_text = primary_message_text
    parts << text_part(primary_text) if primary_text.present?
    referral_context = meta_ad_referral_context
    parts << text_part(referral_context) if referral_context.present?
    parts.concat(attachment_parts(@message.attachments)) if @message.attachments.any?

    return EMPTY_CONTENT if parts.blank?
    return parts.first[:text] if parts.one? && parts.first[:type] == 'text'

    parts
  end

  # The images of the message that get a description: [[attachment, image_url], ...].
  def describable_images
    return [] unless image_understanding_enabled?

    @message.attachments.where(file_type: :image).order(:id).filter_map do |attachment|
      next if sticker_or_gif_attachment?(attachment)

      url = get_attachment_url(attachment)
      [attachment, url] if url.present?
    end
  end

  private

  def primary_message_text
    return voice_call_message_text if @message.voice_call?

    @message.content
  end

  def voice_call_message_text
    transcript = @message.voice_call_transcript_for_llm
    return @message.content if transcript.blank?

    header = @message.content.presence || 'Voice Call'
    "#{header}\nPhone call transcript (Оператор = clinic manager, Клиент = patient):\n#{transcript}"
  end

  def text_part(text)
    { type: 'text', text: text }
  end

  def meta_ad_referral_context
    referral = meta_ad_referral_attributes
    return if referral.blank?

    lines = meta_ad_referral_context_lines(referral)
    return if lines.blank?

    "Meta Ads referral context for this incoming lead:\n#{lines.join("\n")}"
  end

  def meta_ad_referral_attributes
    attributes = @message.content_attributes.to_h.with_indifferent_access
    referral = attributes[:meta_referral].presence ||
               attributes[:meta_ad_referral].presence ||
               attributes[:metaReferral].presence
    return {} unless referral.is_a?(Hash)

    referral.with_indifferent_access
  end

  def meta_ad_referral_context_lines(referral)
    lines = []
    META_AD_REFERRAL_CONTEXT_FIELDS.each do |label, keys|
      append_referral_line(lines, label, referral, *keys)
    end

    ctwa_click_id_present = referral_value(referral, :ctwa_clid, :ctwaClid).present?
    lines = lines.first(ctwa_click_id_present ? 15 : 16)
    lines << 'ctwa click id: present' if ctwa_click_id_present
    lines
  end

  def append_referral_line(lines, label, referral, *keys)
    value = referral_value(referral, *keys)
    return if value.blank?

    lines << "#{label}: #{value.to_s.squish.truncate(500)}"
  end

  def referral_value(referral, *keys)
    keys.lazy.map { |key| referral[key] }.find(&:present?)
  end

  def recognize_image(attachment, image_url)
    Captain::ImageRecognitionService.new(
      account: @message.account,
      attachment: attachment,
      image_url: image_url
    ).perform
  end

  # The text of an image goes through the image budget of the history (like the text of a document, but apart from the text of the
  # conversation): the newest image gets all it needs, an older one what is left, and the dialogue is never pushed out by it.
  def image_text_part(description)
    return if description.blank?
    return text_part("Image attachment: #{description}") if description == Captain::ImageRecognitionService::FALLBACK_DESCRIPTION

    text = @budget ? @budget.image_text(description) : description
    text.present? ? text_part(Captain::ImageReading::Prompt.agent_text(text)) : text_part(Captain::ImageReading::Prompt::IMAGE_LEFT_OUT)
  end

  # The text of an image: the map made beforehand, else the description kept on the attachment (it stays when an administrator purges
  # the file), else a new one.
  def image_description(attachment, image_url)
    made = @image_descriptions && @image_descriptions[attachment.id].to_s.strip
    made.presence || kept_description(attachment) || new_description(attachment, image_url)
  end

  def kept_description(attachment)
    attachment.meta.to_h[Captain::ImageRecognitionService::CACHE_KEY].to_s.strip.presence
  end

  # With a map made beforehand nothing is described here; otherwise the budget limits the calls of a run.
  def new_description(attachment, image_url)
    return if @image_descriptions || image_url.blank?
    return if @budget && !@budget.include_image?

    recognize_image(attachment, image_url)
  end

  def attachment_parts(attachments)
    # In the order the customer sent them: the budget of the image texts goes to the first ones, and the agent reads them in that order.
    image_attachments = attachments.where(file_type: :image).order(:id)
    image_content = image_parts(image_attachments)

    transcription = extract_audio_transcriptions(attachments)
    transcription_part = text_part(transcription) if transcription.present?

    document_text = extract_document_texts(attachments)
    document_part = text_part(document_text) if document_text.present?

    attachment_summary = unparsed_attachment_summary(attachments)
    attachment_part = text_part(attachment_summary) if attachment_summary.present?

    [image_content, transcription_part, document_part, attachment_part].flatten.compact
  end

  def image_parts(image_attachments)
    return [] unless image_understanding_enabled?

    image_attachments.each_with_object([]) do |attachment, parts|
      if sticker_or_gif_attachment?(attachment)
        parts << text_part('User shared a sticker') if @message.content.blank?
        next
      end

      parts.concat(attachment_image_parts(attachment, get_attachment_url(attachment)))
    end.compact
  end

  def attachment_image_parts(attachment, url)
    [image_text_part(image_description(attachment, url))].compact
  end

  def sticker_or_gif_attachment?(attachment)
    return true if @message.content_type.to_s == 'sticker'
    return true if attachment.meta.to_h['is_sticker'] == true
    return true if attachment.external_url.to_s.match?(/giphy\.com|\.gif(\?|\z)/i)
    return true if attachment.extension.to_s.casecmp('gif').zero?

    attachment.file.attached? && attachment.file.blob&.content_type.to_s == 'image/gif'
  end

  def attachment_purged?(attachment)
    return true if attachment.respond_to?(:file_purged?) && attachment.file_purged?
    return true if attachment.respond_to?(:additional_attributes) && attachment.additional_attributes.to_h['file_purged'] == true

    attachment.meta.to_h['file_purged'] == true
  end

  def get_attachment_url(attachment)
    return nil if attachment_purged?(attachment)
    return attachment.download_url if attachment.download_url.present?
    return attachment.external_url if attachment.external_url.present?

    attachment.file.attached? ? attachment.file_url : nil
  end

  def extract_audio_transcriptions(attachments)
    return '' unless @message.account.audio_transcriptions_enabled?
    return '' unless understanding_settings['voice_messages']

    # Keep the customer's order: several voice notes must read in the order they were sent.
    audio_attachments = attachments.where(file_type: :audio).order(:id)
    return '' if audio_attachments.blank?

    audio_attachments.filter_map do |attachment|
      attachment.meta.to_h['transcribed_text'].presence
    end.join
  end

  def extract_document_texts(attachments)
    return '' unless Messages::DocumentParsingService.enabled_for_account?(@message.account)

    file_attachments(attachments).filter_map do |attachment|
      document_text = Messages::DocumentParsingService.extracted_text(attachment)
      next if document_text.blank?

      document_text = @budget.document_text(document_text) if @budget
      next if document_text.blank?

      ["Document attachment: #{attachment_filename(attachment)}", document_text].join("\n")
    end.join("\n\n")
  end

  def unparsed_attachment_summary(attachments)
    document_parse_enabled = Messages::DocumentParsingService.enabled_for_account?(@message.account)
    unparsed_attachments = attachments.where.not(file_type: %i[image audio]).reject do |attachment|
      document_parse_enabled && attachment.file_type == 'file' && Messages::DocumentParsingService.extracted_text(attachment).present?
    end
    return if unparsed_attachments.blank?

    filenames = unparsed_attachments.filter_map { |attachment| attachment_filename(attachment).presence }
    return 'User has shared an attachment' if filenames.blank?

    "User has shared file attachment(s): #{filenames.first(5).join(', ')}"
  end

  def image_understanding_enabled?
    understanding_settings['images']
  end

  # What the AI may read of a message is a workspace setting (Captain::AccountSettings), the same for every agent.
  def understanding_settings
    @understanding_settings ||= Captain::AccountSettings.new(@message.account).section('understanding')
  end

  def file_attachments(attachments)
    attachments.where(file_type: :file)
  end

  def attachment_filename(attachment)
    return attachment.file.blob.filename.to_s if attachment.file.attached?

    attachment.fallback_title.presence || attachment.external_url.to_s.split('/').last.presence
  end
end
