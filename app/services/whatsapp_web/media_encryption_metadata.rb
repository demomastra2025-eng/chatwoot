module WhatsappWeb::MediaEncryptionMetadata
  module_function

  def encrypted_whatsapp_url?(url)
    raw = url.to_s.strip
    return false if raw.blank?

    uri = URI.parse(raw)
    whatsapp_encrypted_host_or_path?(uri.host.to_s.downcase, uri.path.to_s, raw)
  rescue URI::InvalidURIError
    raw.match?(%r{mmg\.whatsapp\.net|\.enc(?:\z|[?&#/])}i)
  end

  def encrypted_media_payload?(options = {})
    opts = options.to_h.deep_symbolize_keys
    return true if first_present([opts], %i[media_key mediaKey direct_path directPath]).present?
    return true if encrypted_whatsapp_url?(first_present([opts], %i[url media_url mediaUrl]))

    %i[filename file_name fileName raw_file_name].any? { |key| opts[key].to_s.strip.match?(/\.enc\z/i) }
  end

  def resolve_media_url(raw_url, direct_path = nil)
    trimmed_url = raw_url.to_s.strip
    return trimmed_url if trimmed_url.present? && !placeholder_whatsapp_url?(trimmed_url)

    trimmed_path = direct_path.to_s.strip
    return "https://mmg.whatsapp.net#{trimmed_path}" if trimmed_path.start_with?('/')

    trimmed_url.presence
  end

  def extract_encryption_metadata(record: {}, attachment_payload: {})
    rec = record.to_h.deep_symbolize_keys
    node_info = WhatsappWeb::MediaMimeNormalizer.extract_media_node(rec)
    sources = [attachment_payload.to_h.deep_symbolize_keys, node_info[:node] || {}, node_info[:top_message] || {}]
    direct_path = first_present(sources, %i[directPath direct_path])

    {
      url: resolve_media_url(first_present(sources, %i[mediaUrl media_url url]), direct_path),
      direct_path: direct_path,
      media_key: first_present(sources, %i[mediaKey media_key]),
      file_sha256: first_present(sources, %i[fileSha256 file_sha256]),
      file_enc_sha256: first_present(sources, %i[fileEncSha256 file_enc_sha256]),
      file_length: first_present(sources, %i[fileLength file_length]),
      media_kind: first_present([sources.first, node_info, rec], %i[media_kind messageType]),
      mime_type: first_present(sources, %i[mimetype mime_type]),
      filename: first_present(sources, %i[fileName file_name filename name])
    }
  end

  def merge_encryption_metadata(primary, secondary)
    pri = primary.to_h.deep_symbolize_keys
    sec = secondary.to_h.deep_symbolize_keys
    sec.compact_blank.merge(pri.compact_blank).merge(
      url: preferred_url(pri, sec),
      mime_type: preferred_mime_type(pri[:mime_type], sec[:mime_type]),
      filename: preferred_filename(pri[:filename], sec[:filename])
    ).compact_blank
  end

  def placeholder_whatsapp_url?(url)
    URI.parse(url).host.to_s.downcase == 'web.whatsapp.net'
  rescue URI::InvalidURIError
    false
  end

  def preferred_url(pri, sec)
    resolve_media_url(pri[:url], pri[:direct_path]) || resolve_media_url(sec[:url], sec[:direct_path])
  end

  def preferred_mime_type(pri_mime, sec_mime)
    return pri_mime if WhatsappWeb::MediaMimeNormalizer.concrete_mime?(pri_mime)
    return sec_mime if WhatsappWeb::MediaMimeNormalizer.concrete_mime?(sec_mime)

    pri_mime.presence || sec_mime.presence
  end

  def preferred_filename(pri_name, sec_name)
    return pri_name unless WhatsappWeb::MediaMimeNormalizer.synthesized_filename?(pri_name)
    return sec_name unless WhatsappWeb::MediaMimeNormalizer.synthesized_filename?(sec_name)

    pri_name.presence || sec_name.presence
  end

  def whatsapp_encrypted_host_or_path?(host, path, raw)
    return true if host == 'mmg.whatsapp.net' || host == 'web.whatsapp.net'
    return true if (host == 'whatsapp.net' || host.end_with?('.whatsapp.net')) && raw.match?(%r{\.enc(?:\z|[?&#/])}i)

    path.match?(/\.enc\z/i)
  end

  def first_present(sources, keys)
    sources.each do |source|
      next unless source.is_a?(Hash)

      keys.each { |key| return source[key] if source[key].present? }
    end
    nil
  end
end
