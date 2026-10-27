# frozen_string_literal: true

class Captain::Conversation::HistoryBudget
  MAX_TEXT_BYTES = 16_000 # Conservative approximation of about 8,000 text tokens.
  MAX_DOCUMENT_BYTES = 8_000 # About 4,000 document text tokens.
  # The text of the images of the history, all together, apart from the text of the conversation: a transcription is long (a page of
  # a lab result is 2-5 KB) and must neither push the dialogue out of the history nor be cut when it is the newest image.
  MAX_IMAGE_BYTES = 8_000
  # What is left of the budget is not worth a cut-down text of an image below this size.
  MIN_IMAGE_BYTES = 200
  IMAGE_CUT_MARK = ' […]'
  # How many images of the history a run may describe by a new call (a description that already exists is free). The agent never
  # receives the pixels of an image, only its description: see Captain::OpenAiMessageBuilderService.
  MAX_IMAGES = 2

  def initialize
    @text_bytes = 0
    @document_bytes = 0
    @image_count = 0
    @image_bytes = 0
    @message_image_bytes = 0
  end

  # The text of the images of the message just built (see #image_text) is not counted here: it has its own budget.
  def include_message?(content, protected: false)
    bytes = [text_bytes(content) - @message_image_bytes, 0].max
    @message_image_bytes = 0
    return false if !protected && @text_bytes + bytes > MAX_TEXT_BYTES

    @text_bytes += bytes
    true
  end

  def include_image?
    return false if @image_count >= MAX_IMAGES

    @image_count += 1
    true
  end

  # The text of an image within the budget of the images. Newest first, as the history is walked: the latest image gets the budget, an
  # older one what is left, cut at the end and marked as cut; '' when too little is left (the caller then says the text is left out).
  def image_text(text)
    available = MAX_IMAGE_BYTES - @image_bytes
    return '' if available < MIN_IMAGE_BYTES

    result = cut_to(text.to_s, available)
    @image_bytes += result.bytesize
    @message_image_bytes += result.bytesize
    result
  end

  def document_text(text)
    available = MAX_DOCUMENT_BYTES - @document_bytes
    return '' if available <= 0

    result = text.to_s.byteslice(0, available).to_s.scrub
    @document_bytes += result.bytesize
    result
  end

  private

  def cut_to(text, available)
    return text if text.bytesize <= available

    text.byteslice(0, available - IMAGE_CUT_MARK.bytesize).to_s.scrub('').rstrip + IMAGE_CUT_MARK
  end

  def text_bytes(content)
    if content.is_a?(Array)
      content.sum { |part| part.is_a?(Hash) && part[:type] == 'text' ? part[:text].to_s.bytesize : 0 }
    else
      content.to_s.bytesize
    end
  end
end
