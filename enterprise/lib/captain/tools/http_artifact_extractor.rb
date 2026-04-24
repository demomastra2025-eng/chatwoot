class Captain::Tools::HttpArtifactExtractor
  FILE_URL_KEY_PATTERN = /(attachment|audio|document|download|file|image|invoice|media|pdf|photo|report|url|video)/i
  URL_PATTERN = %r{https?://[^\s"'<>]+}i
  CONTENT_TYPES_BY_EXTENSION = {
    '.csv' => 'text/csv',
    '.gif' => 'image/gif',
    '.jpeg' => 'image/jpeg',
    '.jpg' => 'image/jpeg',
    '.json' => 'application/json',
    '.mp3' => 'audio/mpeg',
    '.mp4' => 'video/mp4',
    '.ogg' => 'audio/ogg',
    '.pdf' => 'application/pdf',
    '.png' => 'image/png',
    '.txt' => 'text/plain',
    '.webp' => 'image/webp',
    '.xls' => 'application/vnd.ms-excel',
    '.xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '.zip' => 'application/zip'
  }.freeze

  def self.call(**)
    new(**).call
  end

  def initialize(raw_response_body:, formatted_response:, assistant:, custom_tool:)
    @raw_response_body = raw_response_body.to_s
    @formatted_response = formatted_response.to_s
    @assistant = assistant
    @custom_tool = custom_tool
  end

  def call
    candidates = extract_candidates.uniq { |candidate| candidate[:url] }
    candidates.map.with_index(1) { |candidate, index| public_candidate(candidate, index) }
  end

  private

  attr_reader :raw_response_body, :formatted_response, :assistant, :custom_tool

  def extract_candidates
    parsed_body = parse_json(formatted_response)
    return traverse_json(parsed_body, []) if parsed_body.present?

    scan_text_for_urls(formatted_response, ['body'])
  end

  def traverse_json(value, path)
    case value
    when Hash
      candidates = []
      candidates.concat(extract_from_hash(value, path))
      value.each do |key, nested_value|
        candidates.concat(traverse_json(nested_value, path + [key.to_s]))
      end
      candidates
    when Array
      value.flat_map.with_index { |item, index| traverse_json(item, path + [index.to_s]) }
    when String
      key_name = path.last.to_s
      return [] unless key_name.match?(FILE_URL_KEY_PATTERN)

      url_candidate(value, path: path)
    else
      []
    end
  end

  def extract_from_hash(hash, path)
    url_key, url = hash.find do |key, value|
      value.is_a?(String) && key.to_s.match?(FILE_URL_KEY_PATTERN) && http_url?(value)
    end
    return [] if url.blank?

    url_candidate(
      url,
      path: path + [url_key.to_s],
      filename: first_present(hash, 'filename', 'file_name', 'name', 'title'),
      content_type: first_present(hash, 'content_type', 'mime_type', 'mime'),
      size_bytes: first_present(hash, 'size_bytes', 'byte_size', 'content_length', 'size')
    )
  end

  def scan_text_for_urls(text, path)
    text.to_s.scan(URL_PATTERN).flat_map { |url| url_candidate(url, path: path) }
  end

  def url_candidate(url, path:, filename: nil, content_type: nil, size_bytes: nil)
    return [] unless http_url?(url)

    uri = URI.parse(url)
    [
      {
        url: uri.to_s,
        host: uri.host,
        filename: normalized_filename(filename, uri),
        content_type: normalized_content_type(content_type, uri),
        size_bytes: normalized_size(size_bytes),
        source_path: path.join('.')
      }
    ]
  rescue URI::InvalidURIError
    []
  end

  def public_candidate(candidate, index)
    token_payload = {
      account_id: assistant.account_id,
      assistant_id: assistant.id,
      custom_tool_id: custom_tool.id,
      endpoint_host: endpoint_host,
      url: candidate[:url],
      filename: candidate[:filename],
      content_type: candidate[:content_type],
      size_bytes: candidate[:size_bytes]
    }

    {
      id: Captain::Tools::HttpArtifactToken.encode(token_payload),
      kind: 'file',
      source: 'custom_http_tool',
      source_tool_id: custom_tool.id,
      source_tool_slug: custom_tool.slug,
      source_path: candidate[:source_path],
      index: index,
      filename: candidate[:filename],
      content_type: candidate[:content_type],
      size_bytes: candidate[:size_bytes],
      host: candidate[:host]
    }.compact
  end

  def parse_json(body)
    return if body.blank?

    JSON.parse(body)
  rescue JSON::ParserError, TypeError
    nil
  end

  def http_url?(value)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
  rescue URI::InvalidURIError
    false
  end

  def first_present(hash, *keys)
    keys.each do |key|
      value = hash[key] || hash[key.to_sym]
      return value if value.present?
    end
    nil
  end

  def normalized_filename(filename, uri)
    candidate = filename.to_s.presence || File.basename(uri.path.to_s)
    candidate = 'artifact' if candidate.blank? || candidate == '/'
    candidate.split(%r{[\\/]}).last.presence || 'artifact'
  end

  def normalized_content_type(content_type, uri)
    content_type.to_s.presence || CONTENT_TYPES_BY_EXTENSION[File.extname(uri.path.to_s).downcase] || 'application/octet-stream'
  end

  def normalized_size(size_bytes)
    return if size_bytes.blank?

    Integer(size_bytes)
  rescue ArgumentError, TypeError
    nil
  end

  def endpoint_host
    @endpoint_host ||= custom_tool.endpoint_url.to_s[%r{\Ahttps?://([^/:?#]+)}i, 1]
  end
end
