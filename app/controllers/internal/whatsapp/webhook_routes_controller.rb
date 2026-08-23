class Internal::Whatsapp::WebhookRoutesController < ActionController::API
  MAX_TIMESTAMP_SKEW = 300
  BODY_KEYS = %w[destination phone_number_id waba_id].freeze
  DIGITS = /\A\d+\z/
  DESTINATIONS = %w[dev widget].freeze

  before_action :authenticate_route_request!

  def update
    return render_route_conflict if local_prod_owner_exists?

    WhatsappWebhookRoute.create_or_find_by!(
      waba_id: @route_payload.fetch('waba_id'),
      phone_number_id: @route_payload.fetch('phone_number_id'),
      destination: @route_payload.fetch('destination')
    )

    head :no_content
  end

  def destroy
    WhatsappWebhookRoute.where(
      waba_id: @route_payload.fetch('waba_id'),
      phone_number_id: @route_payload.fetch('phone_number_id'),
      destination: @route_payload.fetch('destination')
    ).delete_all

    head :no_content
  end

  private

  def authenticate_route_request!
    @raw_body = request.raw_post.to_s
    @route_payload = parse_route_payload
    return render_invalid_request unless valid_route_payload?
    return render_unauthorized unless valid_timestamp?

    secret = route_registry_secret
    return render_unauthorized if secret.blank?
    return render_unauthorized unless valid_signature?(secret)
  end

  def parse_route_payload
    return {} unless request.media_type == 'application/json'
    return {} if @raw_body.blank?

    JSON.parse(@raw_body)
  rescue JSON::ParserError
    {}
  end

  def valid_route_payload?
    return false unless @route_payload.is_a?(Hash)
    return false unless @route_payload.keys.sort == BODY_KEYS.sort

    valid_identifier?(@route_payload['waba_id']) && valid_identifier?(@route_payload['phone_number_id']) &&
      @route_payload['destination'].is_a?(String) && DESTINATIONS.include?(@route_payload['destination'])
  end

  def valid_identifier?(value)
    value.is_a?(String) && value.match?(DIGITS)
  end

  def valid_timestamp?
    timestamp = request.headers['X-OneLink-Route-Timestamp'].to_s
    return false unless timestamp.match?(/\A\d+\z/)

    (Time.now.to_i - timestamp.to_i).abs <= MAX_TIMESTAMP_SKEW
  end

  def route_registry_secret
    secrets = JSON.parse(ENV.fetch('WHATSAPP_WEBHOOK_ROUTE_REGISTRY_SECRETS', '{}'))
    return unless secrets.is_a?(Hash)

    secrets[@route_payload['destination']].to_s.presence
  rescue JSON::ParserError, TypeError
    nil
  end

  def valid_signature?(secret)
    provided_signature = request.headers['X-OneLink-Route-Signature'].to_s
    return false unless provided_signature.match?(/\Asha256=[0-9a-f]{64}\z/)

    signed_payload = [request.request_method, @route_payload.fetch('destination'),
                      request.headers['X-OneLink-Route-Timestamp'], @raw_body].join("\n")
    expected_signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, signed_payload)}"
    ActiveSupport::SecurityUtils.secure_compare(expected_signature, provided_signature)
  rescue ArgumentError
    false
  end

  def local_prod_owner_exists?
    WhatsappWebhookRoute.local_prod_owner_exists?(
      @route_payload.fetch('waba_id'),
      @route_payload.fetch('phone_number_id')
    )
  end

  def render_invalid_request
    render json: { error: 'invalid_request' }, status: :bad_request
  end

  def render_unauthorized
    render json: { error: 'unauthorized' }, status: :unauthorized
  end

  def render_route_conflict
    render json: { error: 'local_prod_owner' }, status: :conflict
  end
end
