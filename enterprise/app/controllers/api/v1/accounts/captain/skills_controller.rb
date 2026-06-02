# frozen_string_literal: true

require 'net/http'
require 'ipaddr'
require 'socket'

class Api::V1::Accounts::Captain::SkillsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Captain::Skill) }
  before_action :set_skill, only: [:show, :update, :destroy]

  MAX_IMPORT_BYTES = 200.kilobytes
  IMPORT_TIMEOUT_SECONDS = 10
  DISALLOWED_HOSTS = ['localhost'].freeze
  DISALLOWED_HOST_SUFFIXES = ['.local', '.localhost'].freeze
  DISALLOWED_IP_RANGES = %w[
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
    240.0.0.0/4
    ::/128 ::1/128 ::/96 ::ffff:0:0/96
    fc00::/7 fe80::/10 ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  def index
    skills = Current.account.captain_skills.search(params[:search]).ordered
    render json: {
      payload: skills.map(&:as_api_json),
      meta: { total_count: skills.count, page: 1 }
    }
  end

  def show
    render json: @skill.as_api_json
  end

  def create
    skill = Current.account.captain_skills.create!(skill_params)
    render json: skill.as_api_json
  rescue ActiveRecord::RecordInvalid => e
    render_could_not_create_error(e.record.errors.full_messages.join(', '))
  end

  def update
    @skill.update!(skill_params)
    render json: @skill.as_api_json
  rescue ActiveRecord::RecordInvalid => e
    render_could_not_create_error(e.record.errors.full_messages.join(', '))
  end

  def import
    import_endpoint = normalized_import_endpoint(import_params[:url])
    source_url = import_endpoint[:uri].to_s
    markdown = fetch_import_markdown(import_endpoint)
    attributes = Captain::Skill.attributes_from_markdown(markdown, source_url: source_url)
    skill = Current.account.captain_skills.find_or_initialize_by(slug: attributes[:slug])
    skill.assign_attributes(attributes)
    skill.save!

    render json: skill.as_api_json
  rescue ActiveRecord::RecordInvalid => e
    render_could_not_create_error(e.record.errors.full_messages.join(', '))
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def destroy
    @skill.destroy
    head :no_content
  end

  private

  def set_skill
    @skill = Current.account.captain_skills.find(params[:id])
  end

  def skill_params
    params.require(:skill).permit(:name, :description, :content, :group_name, :source_url, metadata: {})
  end

  def import_params
    params.permit(:url)
  end

  def normalized_import_endpoint(raw_url)
    uri = parse_import_uri(raw_url)
    uri = github_blob_raw_uri(uri)
    validate_import_uri!(uri)
    { uri: uri, ip_address: validated_import_ip_address(uri.host) }
  end

  def parse_import_uri(raw_url)
    uri = URI.parse(raw_url.to_s.strip)
    raise I18n.t('captain.skills.import.invalid_url') unless uri.is_a?(URI::HTTP)

    uri
  rescue URI::InvalidURIError
    raise I18n.t('captain.skills.import.invalid_url')
  end

  def github_blob_raw_uri(uri)
    return uri unless uri.host == 'github.com'

    parts = uri.path.split('/').reject(&:blank?)
    blob_index = parts.index('blob')
    return uri unless parts.length >= 5 && blob_index == 2

    owner = parts[0]
    repo = parts[1]
    ref = parts[3]
    file_path = parts[4..].join('/')
    URI.parse("https://raw.githubusercontent.com/#{owner}/#{repo}/#{ref}/#{file_path}")
  end

  def validate_import_uri!(uri)
    raise I18n.t('captain.skills.import.https_required') unless uri.scheme == 'https'
    raise I18n.t('captain.skills.import.invalid_url') if uri.host.blank?

    normalized_host = normalize_import_host(uri.host)
    return unless DISALLOWED_HOSTS.include?(normalized_host) || DISALLOWED_HOST_SUFFIXES.any? { |suffix| normalized_host.end_with?(suffix) }

    raise I18n.t('captain.skills.import.local_url')
  end

  def normalize_import_host(host)
    host.to_s.downcase.delete_suffix('.')
  end

  def resolved_import_ip_addresses(host)
    literal_ip = parse_ip_address(host)
    return [literal_ip] if literal_ip

    Addrinfo.getaddrinfo(host, nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
            .filter_map { |addrinfo| parse_ip_address(addrinfo.ip_address) }
            .uniq
  end

  def parse_ip_address(value)
    IPAddr.new(value.to_s)
  rescue IPAddr::InvalidAddressError
    nil
  end

  def disallowed_import_ip?(address)
    DISALLOWED_IP_RANGES.any? { |range| range.include?(address) }
  end

  def validated_import_ip_address(host)
    addresses = resolved_import_ip_addresses(normalize_import_host(host))
    raise I18n.t('captain.skills.import.local_url') if addresses.blank? || addresses.any? { |address| disallowed_import_ip?(address) }

    addresses.first
  rescue SocketError
    raise I18n.t('captain.skills.import.local_url')
  end

  def fetch_import_markdown(import_endpoint)
    body = download_import_markdown(import_endpoint[:uri], import_endpoint[:ip_address])
    validate_import_markdown!(body)
    body
  end

  def download_import_markdown(uri, ip_address)
    body = +''

    start_import_http(uri, ip_address) do |http|
      http.request(import_request(uri)) do |response|
        validate_import_response!(response)
        response.read_body do |chunk|
          body << chunk.to_s
          raise I18n.t('captain.skills.import.too_large') if body.bytesize > MAX_IMPORT_BYTES
        end
      end
    end

    body
  end

  def start_import_http(uri, ip_address, &)
    Net::HTTP.new(uri.host, uri.port).tap do |http|
      # Keep the original host for TLS/SNI/Host headers, but pin the TCP connection to the
      # already-validated address so DNS cannot rebind between validation and fetch.
      http.ipaddr = ip_address.to_s
      http.use_ssl = true
      http.open_timeout = http.read_timeout = IMPORT_TIMEOUT_SECONDS
      http.start(&)
    end
  end

  def import_request(uri)
    Net::HTTP::Get.new(uri.request_uri).tap do |request|
      request['Accept'] = 'text/plain, text/markdown, */*'
    end
  end

  def validate_import_response!(response)
    raise I18n.t('captain.skills.import.fetch_failed', code: response.code) unless response.is_a?(Net::HTTPSuccess)

    validate_import_response_length!(response)
  end

  def validate_import_markdown!(body)
    raise I18n.t('captain.skills.import.missing_skill_md') unless body.include?('---') && body.include?('description:')
  end

  def validate_import_response_length!(response)
    content_length = response['Content-Length'].to_i if response['Content-Length'].present?
    raise I18n.t('captain.skills.import.too_large') if content_length.to_i > MAX_IMPORT_BYTES
  end
end
