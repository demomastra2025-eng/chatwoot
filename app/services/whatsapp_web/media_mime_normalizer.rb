module WhatsappWeb::MediaMimeNormalizer
  MEDIA_NODE_KINDS = { imageMessage: 'image', stickerMessage: 'sticker', videoMessage: 'video', ptvMessage: 'ptv',
                       audioMessage: 'audio', documentMessage: 'document' }.freeze
  WRAPPER_KEYS = %i[associatedChildMessage ephemeralMessage viewOnceMessage viewOnceMessageV2
                    viewOnceMessageV2Extension editedMessage documentWithCaptionMessage].freeze
  CANONICAL_KIND_MAP = {
    'image' => 'image', 'imagemessage' => 'image', 'sticker' => 'sticker', 'stickermessage' => 'sticker', 'video' => 'video',
    'videomessage' => 'video', 'ptv' => 'video', 'ptvmessage' => 'video', 'audio' => 'audio', 'audiomessage' => 'audio', 'ptt' => 'audio',
    'voice' => 'audio', 'document' => 'document', 'documentmessage' => 'document', 'documentwithcaptionmessage' => 'document', 'file' => 'document'
  }.freeze
  FILE_TYPE_BY_KIND = { 'image' => 'image', 'sticker' => 'image', 'video' => 'video', 'audio' => 'audio', 'document' => 'file' }.freeze
  DEFAULT_MIME_BY_KIND = { 'image' => 'image/jpeg', 'sticker' => 'image/webp', 'video' => 'video/mp4',
                           'audio' => 'audio/ogg', 'document' => 'application/octet-stream' }.freeze
  DEFAULT_EXT_BY_KIND = { 'image' => 'jpg', 'sticker' => 'webp', 'video' => 'mp4', 'audio' => 'ogg', 'document' => 'bin' }.freeze
  GENERIC_MIMES = %w[application/octet-stream binary/octet-stream application/encrypted].freeze
  SYNTHESIZED_FILENAME_REGEX = /\Awhatsapp-web-[0-9a-f]{6,32}(?:\.[a-z0-9]+)?\z/i
  MIME_TO_EXTENSION = {
    'image/jpeg' => 'jpg', 'image/jpg' => 'jpg', 'image/png' => 'png', 'image/webp' => 'webp', 'image/gif' => 'gif', 'image/heic' => 'heic',
    'image/heif' => 'heif', 'image/bmp' => 'bmp', 'image/svg+xml' => 'svg', 'video/mp4' => 'mp4', 'video/3gpp' => '3gp', 'video/quicktime' => 'mov',
    'video/webm' => 'webm', 'video/x-matroska' => 'mkv', 'video/mpeg' => 'mpeg', 'video/x-msvideo' => 'avi', 'audio/ogg' => 'ogg',
    'audio/opus' => 'opus', 'audio/mpeg' => 'mp3', 'audio/mp3' => 'mp3', 'audio/mp4' => 'm4a', 'audio/x-m4a' => 'm4a', 'audio/aac' => 'aac',
    'audio/wav' => 'wav', 'audio/x-wav' => 'wav', 'audio/amr' => 'amr', 'audio/webm' => 'webm', 'application/pdf' => 'pdf',
    'application/msword' => 'doc', 'application/vnd.ms-excel' => 'xls', 'application/vnd.ms-powerpoint' => 'ppt',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'docx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation' => 'pptx',
    'application/vnd.oasis.opendocument.text' => 'odt', 'text/csv' => 'csv', 'text/plain' => 'txt', 'text/rtf' => 'rtf', 'application/rtf' => 'rtf',
    'text/html' => 'html', 'text/xml' => 'xml', 'application/xml' => 'xml', 'application/json' => 'json', 'application/zip' => 'zip',
    'application/x-zip-compressed' => 'zip', 'application/vnd.rar' => 'rar', 'application/x-rar-compressed' => 'rar',
    'application/x-7z-compressed' => '7z', 'application/x-tar' => 'tar', 'application/gzip' => 'gz'
  }.freeze

  module_function

  def canonical_media_kind(kind) = CANONICAL_KIND_MAP[kind.to_s.strip.downcase]
  def base_mime(mime_type) = mime_type.to_s.split(';').first.to_s.strip.downcase
  def concrete_mime?(mime) = mime.present? && GENERIC_MIMES.exclude?(mime)
  def synthesized_filename?(filename) = filename.blank? || filename.to_s.strip.match?(SYNTHESIZED_FILENAME_REGEX)

  def file_type_for(media_kind: nil, mime_type: nil)
    canonical = canonical_media_kind(media_kind)
    return FILE_TYPE_BY_KIND.fetch(canonical, 'file') if canonical.present?

    base = base_mime(mime_type)
    %w[image video audio].find { |prefix| base.start_with?("#{prefix}/") } || 'file'
  end

  def strip_enc_filename(filename)
    raw = filename.to_s.split(/[?#]/).first.to_s.strip
    File.basename(raw).sub(/(?:\.enc)+\z/i, '').strip.presence if raw.present?
  end

  def clean_extension(filename)
    stripped = strip_enc_filename(filename)
    return if stripped.blank?

    ext = File.extname(stripped).delete_prefix('.').downcase
    ext.match?(/\A[a-z0-9]{1,10}\z/) && ext != 'enc' && !ext.match?(/\A\d+\z/) ? ext : nil
  end

  def normalize_mime_type(mime_type, filename: nil, media_kind: nil)
    base = base_mime(mime_type)
    return base if concrete_mime?(base)

    inferred = mime_from_filename(filename)
    concrete_mime?(inferred) ? inferred : (DEFAULT_MIME_BY_KIND[canonical_media_kind(media_kind)] || 'application/octet-stream')
  end

  def extension_for(mime_type: nil, filename: nil, media_kind: nil)
    clean_extension(filename) ||
      MIME_TO_EXTENSION[normalize_mime_type(mime_type, filename: filename, media_kind: media_kind)] ||
      DEFAULT_EXT_BY_KIND[canonical_media_kind(media_kind)] || 'bin'
  end

  def sanitize_filename(filename, mime_type: nil, media_kind: nil, fallback_prefix: 'whatsapp-web')
    ext = extension_for(mime_type: mime_type, filename: filename, media_kind: media_kind)
    stripped = strip_enc_filename(filename)
    return "#{fallback_prefix}-#{SecureRandom.hex(6)}.#{ext}" if stripped.blank?

    clean_extension(stripped).present? ? stripped : "#{stripped}.#{ext}"
  end

  def extract_media_node(record)
    top_message = record.to_h.deep_symbolize_keys[:message].to_h.deep_symbolize_keys
    unwrapped = unwrap_message_container(top_message)
    MEDIA_NODE_KINDS.each do |message_key, media_kind|
      node = unwrapped[message_key]
      return { media_kind: media_kind, message_key: message_key, node: node.deep_symbolize_keys, top_message: top_message } if valid_node?(node)
    end
    {}
  end

  def valid_node?(node) = node.is_a?(Hash) && node.present?

  def unwrap_message_container(message)
    current = message.to_h.deep_symbolize_keys
    3.times do
      wrapper_key = WRAPPER_KEYS.find { |key| current[key].is_a?(Hash) && current.dig(key, :message).is_a?(Hash) }
      break unless wrapper_key

      current = current.dig(wrapper_key, :message).deep_symbolize_keys
    end
    current
  end

  def mime_from_filename(filename)
    stripped = strip_enc_filename(filename)
    Marcel::MimeType.for(name: stripped).to_s.downcase.presence if stripped.present? && clean_extension(stripped).present?
  rescue StandardError
    nil
  end
end
