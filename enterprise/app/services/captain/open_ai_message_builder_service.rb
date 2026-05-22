class Captain::OpenAiMessageBuilderService
  pattr_initialize [:message!]

  # Extracts text and image URLs from multimodal content array (reverse of generate_content)
  def self.extract_text_and_attachments(content)
    Llm::MessageFormat.extract_text_and_attachments(content)
  end

  def generate_content
    parts = []
    parts << text_part(@message.content) if @message.content.present?
    parts.concat(attachment_parts(@message.attachments)) if @message.attachments.any?

    return 'Message without content' if parts.blank?
    return parts.first[:text] if parts.one? && parts.first[:type] == 'text'

    parts
  end

  private

  def text_part(text)
    { type: 'text', text: text }
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

    attachment_part = text_part('User has shared an attachment') if attachments.where.not(file_type: %i[image audio]).exists?

    [image_content, transcription_part, attachment_part].flatten.compact
  end

  def image_parts(image_attachments)
    image_attachments.each_with_object([]) do |attachment, parts|
      url = get_attachment_url(attachment)
      parts << image_description_part(attachment, url) if url.present?
    end
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
end
