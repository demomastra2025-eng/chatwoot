# frozen_string_literal: true

class Captain::Conversation::HistoryBudget
  MAX_TEXT_BYTES = 16_000 # Conservative approximation of about 8,000 text tokens.
  MAX_DOCUMENT_BYTES = 8_000 # About 4,000 document text tokens.
  MAX_IMAGES = 2

  def initialize
    @text_bytes = 0
    @document_bytes = 0
    @image_count = 0
  end

  def include_message?(content, protected: false)
    bytes = text_bytes(content)
    return false if !protected && @text_bytes + bytes > MAX_TEXT_BYTES

    @text_bytes += bytes
    true
  end

  def include_image?
    return false if @image_count >= MAX_IMAGES

    @image_count += 1
    true
  end

  def document_text(text)
    available = MAX_DOCUMENT_BYTES - @document_bytes
    return '' if available <= 0

    result = text.to_s.byteslice(0, available).to_s.scrub
    @document_bytes += result.bytesize
    result
  end

  private

  def text_bytes(content)
    if content.is_a?(Array)
      content.sum { |part| part.is_a?(Hash) && part[:type] == 'text' ? part[:text].to_s.bytesize : 0 }
    else
      content.to_s.bytesize
    end
  end
end
