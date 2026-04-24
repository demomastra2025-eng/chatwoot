require 'cgi'
require 'ipaddr'
require 'net/http'
require 'resolv'
require 'stringio'

class Captain::Tools::HttpArtifactMaterializer
  MAX_REDIRECTS = 3
  PRIVATE_NETWORKS = %w[
    0.0.0.0/8
    10.0.0.0/8
    100.64.0.0/10
    127.0.0.0/8
    169.254.0.0/16
    172.16.0.0/12
    192.0.0.0/24
    192.0.2.0/24
    192.168.0.0/16
    198.18.0.0/15
    198.51.100.0/24
    203.0.113.0/24
    224.0.0.0/4
    ::/128
    ::1/128
    fc00::/7
    fe80::/10
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  class DownloadError < StandardError; end
  class UnsafeUrlError < DownloadError; end

  def initialize(account:, assistant:)
    @account = account
    @assistant = assistant
  end

  def materialize!(artifact_id)
    @payload = Captain::Tools::HttpArtifactToken.decode(artifact_id)
    validate_scope!

    response = fetch_response(validated_uri(payload[:url]))
    body = response.body.to_s
    assert_storage_available!(body.bytesize)

    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(body),
      filename: filename_for(response),
      content_type: content_type_for(response),
      metadata: {
        'account_id' => account.id,
        'source' => 'captain_http_artifact',
        'assistant_id' => assistant.id,
        'custom_tool_id' => payload[:custom_tool_id]
      }.compact
    )
    blob.signed_id
  end

  private

  attr_reader :account, :assistant, :payload

  def validate_scope!
    raise Captain::Tools::HttpArtifactToken::InvalidToken, 'Artifact id belongs to another account' if payload[:account_id].to_i != account.id
    raise Captain::Tools::HttpArtifactToken::InvalidToken, 'Artifact id belongs to another assistant' if payload[:assistant_id].to_i != assistant.id
  end

  def fetch_response(uri, redirect_count: 0)
    raise DownloadError, 'Too many redirects while downloading artifact' if redirect_count > MAX_REDIRECTS

    validate_public_uri!(uri)
    uri = uri_with_query_auth(uri)
    resolved_ip = resolve_public_ip!(uri)
    request = Net::HTTP::Get.new(uri)
    apply_auth!(request, uri)

    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = resolved_ip
    http.use_ssl = uri.is_a?(URI::HTTPS)
    http.open_timeout = 5
    http.read_timeout = 30
    http.max_retries = 0

    http.request(request) do |response|
      case response
      when Net::HTTPSuccess
        stream_success_response!(response)
      when Net::HTTPRedirection
        location = response['location'].to_s
        raise DownloadError, 'Artifact redirect is missing location' if location.blank?

        return fetch_response(validated_uri(URI.join(uri.to_s, location).to_s), redirect_count: redirect_count + 1)
      else
        raise DownloadError, "Failed to download artifact: HTTP #{response.code}"
      end
    end
  end

  def validated_uri(url)
    uri = URI.parse(url.to_s)
    validate_public_uri!(uri)
    uri
  rescue URI::InvalidURIError
    raise UnsafeUrlError, 'Invalid artifact URL'
  end

  def validate_public_uri!(uri)
    raise UnsafeUrlError, 'Artifact URL must be HTTP or HTTPS' unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    raise UnsafeUrlError, 'Artifact URL host is required' if uri.host.blank?
    raise UnsafeUrlError, 'Artifact URL userinfo is not allowed' if uri.userinfo.present?

    resolve_public_ip!(uri)
  end

  def resolve_public_ip!(uri)
    addresses = Resolv.getaddresses(uri.host)
    raise UnsafeUrlError, 'Artifact URL host could not be resolved' if addresses.blank?

    addresses.each do |address|
      ip = IPAddr.new(address)
      raise UnsafeUrlError, 'Artifact URL resolves to a private or reserved address' if PRIVATE_NETWORKS.any? { |network| network.include?(ip) }
    end

    addresses.first
  rescue Resolv::ResolvError, IPAddr::InvalidAddressError
    raise UnsafeUrlError, 'Artifact URL host could not be resolved'
  end

  def stream_success_response!(response)
    assert_size_allowed!(response['content-length'].to_i) if response['content-length'].present?

    body = ''.b
    response.read_body do |chunk|
      body << chunk
      assert_size_allowed!(body.bytesize)
    end
    response.body = body
    response
  end

  def apply_auth!(request, uri)
    tool = same_host_custom_tool(uri)
    return if tool.blank?

    tool.build_auth_headers.each { |key, value| request[key] = value }
    basic_credentials = tool.build_basic_auth_credentials
    request.basic_auth(*basic_credentials) if basic_credentials.present?
  end

  def uri_with_query_auth(uri)
    tool = same_host_custom_tool(uri)
    return uri if tool.blank? || tool.auth_type != 'api_key'

    auth_config = tool.auth_config.with_indifferent_access
    return uri unless auth_config[:location] == 'query'
    return uri if auth_config[:name].blank? || auth_config[:key].blank?

    cloned_uri = uri.dup
    query_pairs = URI.decode_www_form(cloned_uri.query.to_s)
    query_pairs.reject! { |key, _value| key == auth_config[:name] }
    query_pairs << [auth_config[:name], auth_config[:key].to_s]
    cloned_uri.query = URI.encode_www_form(query_pairs)
    cloned_uri
  end

  def same_host_custom_tool(uri)
    tool = custom_tool
    return if tool.blank?

    tool if same_host?(uri.host, payload[:endpoint_host].presence || custom_tool_endpoint_host(tool))
  end

  def custom_tool_endpoint_host(tool)
    tool.endpoint_url.to_s[%r{\Ahttps?://([^/:?#]+)}i, 1]
  end

  def custom_tool
    @custom_tool ||= Captain::CustomTool.find_by(id: payload[:custom_tool_id], account_id: account.id)
  end

  def same_host?(left, right)
    left.to_s.casecmp(right.to_s).zero?
  end

  def filename_for(response)
    content_disposition_filename(response['content-disposition']) ||
      payload[:filename].to_s.presence ||
      File.basename(URI.parse(payload[:url].to_s).path.to_s).presence ||
      'artifact'
  end

  def content_disposition_filename(header)
    return if header.blank?

    header[/filename\*=UTF-8''([^;]+)/i, 1]&.then { |value| CGI.unescape(value) } ||
      header[/filename="?([^";]+)"?/i, 1]
  end

  def content_type_for(response)
    response.content_type.presence || payload[:content_type].to_s.presence || 'application/octet-stream'
  end

  def assert_size_allowed!(byte_size)
    return if byte_size.to_i <= 0
    return if byte_size.to_i <= maximum_file_upload_bytes

    raise DownloadError, 'Artifact file size exceeds the maximum upload size'
  end

  def assert_storage_available!(byte_size)
    return if AccountLimits::StorageUsageService.new(account: account).within_limit?(extra_bytes: byte_size)

    raise AccountLimits::StorageUsageService::LimitExceeded, AccountLimits::StorageUsageService::LIMIT_EXCEEDED_MESSAGE
  end

  def maximum_file_upload_bytes
    configured_limit = GlobalConfigService.load('MAXIMUM_FILE_UPLOAD_SIZE', 40).to_i
    configured_limit = 40 if configured_limit <= 0
    configured_limit.megabytes
  end
end
