# frozen_string_literal: true

class Meta::AuthorizationHealthCheckService
  GRAPH_BASE_URI = 'https://graph.facebook.com'
  INSTAGRAM_GRAPH_BASE_URI = 'https://graph.instagram.com'
  REQUEST_TIMEOUT = 10

  def initialize(channel)
    @channel = channel
  end

  def healthy?
    return false if @channel.blank?

    case @channel
    when Channel::Instagram
      instagram_healthy?
    when Channel::FacebookPage
      facebook_page_healthy?
    when Channel::Whatsapp
      whatsapp_cloud_healthy?
    else
      false
    end
  rescue StandardError => e
    Rails.logger.warn("[META AUTH HEALTH] #{@channel.class.name} #{@channel.id}: #{e.class}: #{e.message}")
    false
  end

  private

  def instagram_healthy?
    token = @channel[:access_token]
    return false if token.blank?
    return false if @channel.expires_at.present? && Time.current >= @channel.expires_at

    version = GlobalConfigService.load('INSTAGRAM_API_VERSION', 'v22.0')
    token_ok = successful_graph_get?(
      "#{INSTAGRAM_GRAPH_BASE_URI}/#{version}/me",
      query: { fields: 'id,username', access_token: token }
    )
    return false unless token_ok

    successful_instagram_subscription_get?(
      "#{INSTAGRAM_GRAPH_BASE_URI}/#{version}/#{@channel.instagram_id}/subscribed_apps",
      query: { access_token: token }
    )
  end

  def facebook_page_healthy?
    token = @channel.page_access_token
    page_id = @channel.page_id
    return false if token.blank? || page_id.blank?

    version = GlobalConfigService.load('FACEBOOK_API_VERSION', 'v18.0')
    successful_graph_get?(
      "#{GRAPH_BASE_URI}/#{version}/#{page_id}",
      query: { fields: 'id', access_token: token },
      expected_id: page_id
    )
  end

  def whatsapp_cloud_healthy?
    return false unless @channel.provider == 'whatsapp_cloud'

    config = @channel.provider_config.to_h
    token = config['api_key']
    phone_number_id = config['phone_number_id']
    return false if token.blank? || phone_number_id.blank?

    version = GlobalConfigService.load('WHATSAPP_API_VERSION', 'v22.0')
    successful_graph_get?(
      "#{GRAPH_BASE_URI}/#{version}/#{phone_number_id}",
      query: { fields: 'id', access_token: token }.merge(whatsapp_appsecret_proof_query(token)),
      expected_id: phone_number_id
    )
  end

  def successful_graph_get?(url, query:, expected_id: nil)
    response = HTTParty.get(url, query: query, headers: { 'Accept' => 'application/json' }, timeout: REQUEST_TIMEOUT)
    return false unless response.respond_to?(:success?) && response.success?
    return true if expected_id.blank?

    parsed_response(response)['id'].to_s == expected_id.to_s
  end

  def successful_instagram_subscription_get?(url, query:)
    response = HTTParty.get(url, query: query, headers: { 'Accept' => 'application/json' }, timeout: REQUEST_TIMEOUT)
    return false unless response.respond_to?(:success?) && response.success?

    Array(parsed_response(response)['data']).present?
  end

  def parsed_response(response)
    parsed = response.parsed_response
    return parsed.to_h if parsed.respond_to?(:to_h)

    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    {}
  end

  def whatsapp_appsecret_proof_query(token)
    Whatsapp::FacebookApiClient.appsecret_proof_query(token).to_h
  end
end
