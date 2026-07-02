class Captain::OpenAiMessageBuilderService
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

  pattr_initialize [:message!]

  # Extracts text and image URLs from multimodal content array (reverse of generate_content)
  def self.extract_text_and_attachments(content)
    Llm::MessageFormat.extract_text_and_attachments(content)
  end

  def generate_content
    parts = []
    parts << text_part(@message.content) if @message.content.present?
    referral_context = meta_ad_referral_context
    parts << text_part(referral_context) if referral_context.present?
    parts.concat(attachment_parts(@message.attachments)) if @message.attachments.any?

    return 'Message without content' if parts.blank?
    return parts.first[:text] if parts.one? && parts.first[:type] == 'text'

    parts
  end

  private

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

  def image_description_part(attachment, image_url)
    description = Captain::ImageRecognitionService.new(
      account: @message.account,
      attachment: attachment,
      image_url: image_url
    ).perform
    text_part("Image attachment: #{description}") if description.present?
  end

  def attachment_parts(attachments)
    image_attachments = attachments.where(file_type: :image)
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
    image_attachments.each_with_object([]) do |attachment, parts|
      url = get_attachment_url(attachment)
      next if url.blank?

      parts << image_url_part(url)
      parts << image_description_part(attachment, url)
    end.compact
  end

  def image_url_part(url)
    { type: 'image_url', image_url: { url: url } }
  end

  def get_attachment_url(attachment)
    return attachment.download_url if attachment.download_url.present?
    return attachment.external_url if attachment.external_url.present?

    attachment.file.attached? ? attachment.file_url : nil
  end

  def extract_audio_transcriptions(attachments)
    return '' unless @message.account.captain_audio_transcription_enabled?

    audio_attachments = attachments.where(file_type: :audio)
    return '' if audio_attachments.blank?

    audio_attachments.filter_map do |attachment|
      attachment.meta.to_h['transcribed_text'].presence
    end.join
  end

  def extract_document_texts(attachments)
    return '' unless Llm::RuntimePolicy.web_access_enabled?(:document_parse, account: @message.account)

    file_attachments(attachments).filter_map do |attachment|
      document_text = Messages::DocumentParsingService.extracted_text(attachment)
      next if document_text.blank?

      ["Document attachment: #{attachment_filename(attachment)}", document_text].join("\n")
    end.join("\n\n")
  end

  def unparsed_attachment_summary(attachments)
    document_parse_enabled = Llm::RuntimePolicy.web_access_enabled?(:document_parse, account: @message.account)
    unparsed_attachments = attachments.where.not(file_type: %i[image audio]).reject do |attachment|
      document_parse_enabled && attachment.file_type == 'file' && Messages::DocumentParsingService.extracted_text(attachment).present?
    end
    return if unparsed_attachments.blank?

    filenames = unparsed_attachments.filter_map { |attachment| attachment_filename(attachment).presence }
    return 'User has shared an attachment' if filenames.blank?

    "User has shared file attachment(s): #{filenames.first(5).join(', ')}"
  end

  def file_attachments(attachments)
    attachments.where(file_type: :file)
  end

  def attachment_filename(attachment)
    return attachment.file.blob.filename.to_s if attachment.file.attached?

    attachment.fallback_title.presence || attachment.external_url.to_s.split('/').last.presence
  end
end
