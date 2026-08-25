class Internal::Whatsapp::WebhookRoutesController < ActionController::API
  MAX_TIMESTAMP_SKEW = 300
  BODY_KEYS = %w[destination phone_number_id waba_id].freeze
  CONDITIONAL_DELETE_KEYS = (BODY_KEYS + %w[registration_token]).freeze
  DIGITS = /\A\d+\z/
  REGISTRATION_TOKEN = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  DESTINATIONS = %w[dev widget].freeze
  REGISTRATION_TOKEN_HEADER = 'X-OneLink-Route-Registration-Token'.freeze

  before_action :authenticate_route_request!

  def update
    return render_route_conflict if local_prod_owner_exists?

    created, registration_token = with_waba_registry_lock do
      initial_token = SecureRandom.uuid
      route = WhatsappWebhookRoute.create_or_find_by!(route_identity) do |record|
        record.registration_token = initial_token
      end
      created = route.previously_new_record?
      route.update!(registration_token: initial_token) if route.registration_token.blank?
      [created, route.registration_token]
    end

    response.set_header(REGISTRATION_TOKEN_HEADER, registration_token)
    head(created ? :created : :no_content)
  end

  def destroy
    return render_registration_token_required unless conditional_delete?

    stale_generation = with_waba_registry_lock do
      routes = WhatsappWebhookRoute.where(route_identity)
      deleted = routes.where(registration_token: @route_payload.fetch('registration_token')).delete_all
      deleted.zero? && routes.exists?
    end

    return render_route_generation_conflict if stale_generation

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
    return false unless valid_route_payload_keys?

    valid_identifier?(@route_payload['waba_id']) && valid_identifier?(@route_payload['phone_number_id']) &&
      @route_payload['destination'].is_a?(String) && DESTINATIONS.include?(@route_payload['destination']) &&
      valid_registration_token?
  end

  def valid_route_payload_keys?
    keys = @route_payload.keys.sort
    keys == BODY_KEYS.sort || (request.delete? && keys == CONDITIONAL_DELETE_KEYS.sort)
  end

  def valid_registration_token?
    return true unless conditional_delete?

    @route_payload['registration_token'].is_a?(String) && @route_payload['registration_token'].match?(REGISTRATION_TOKEN)
  end

  def conditional_delete? = @route_payload.key?('registration_token')

  def route_identity
    {
      waba_id: @route_payload.fetch('waba_id'),
      phone_number_id: @route_payload.fetch('phone_number_id'),
      destination: @route_payload.fetch('destination')
    }
  end

  def with_waba_registry_lock(&)
    WhatsappWebhookRoute.with_waba_registry_lock(@route_payload.fetch('waba_id'), &)
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

  def render_route_generation_conflict
    render json: { error: 'stale_registration_token' }, status: :conflict
  end

  def render_registration_token_required
    render json: { error: 'registration_token_required' }, status: :conflict
  end
end
