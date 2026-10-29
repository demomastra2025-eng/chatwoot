class Api::V1::Integrations::WebhooksController < ActionController::API
  SLACK_SIGNATURE_MAX_SKEW_SECONDS = 300

  before_action :verify_slack_signature!

  def create
    builder = Integrations::Slack::IncomingMessageBuilder.new(permitted_params)
    response = builder.perform
    render json: response
  end

  private

  def verify_slack_signature!
    secret = slack_signing_secret
    timestamp = request.headers['X-Slack-Request-Timestamp'].to_s.strip
    signature = request.headers['X-Slack-Signature'].to_s.strip

    return if secret.present? && fresh_timestamp?(timestamp) && valid_signature?(secret, timestamp, signature)

    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  def slack_signing_secret
    ENV.fetch('SLACK_SIGNING_SECRET', nil).to_s.strip.presence ||
      GlobalConfigService.load('SLACK_SIGNING_SECRET', nil).to_s.strip.presence
  end

  def fresh_timestamp?(timestamp)
    return false unless timestamp.match?(/\A\d+\z/)

    (Time.now.to_i - timestamp.to_i).abs <= SLACK_SIGNATURE_MAX_SKEW_SECONDS
  end

  def valid_signature?(secret, timestamp, signature)
    basestring = "v0:#{timestamp}:#{request.raw_post}"
    expected = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, basestring)}"
    signature.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(signature, expected)
  end

  # TODO: This is a temporary solution to permit all params for slack unfurling job.
  # We should only permit the params that we use. Handle all the params based on events and send it to the respective services.
  def permitted_params
    params.permit!
  end
end
