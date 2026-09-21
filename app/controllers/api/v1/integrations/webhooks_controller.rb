class Api::V1::Integrations::WebhooksController < ApplicationController
  SLACK_SIGNATURE_VERSION = 'v0'.freeze
  SLACK_SIGNATURE_TOLERANCE = 5.minutes

  def create
    return head :unauthorized unless valid_slack_signature?

    builder = Integrations::Slack::IncomingMessageBuilder.new(slack_payload)
    response = builder.perform
    render json: response
  rescue JSON::ParserError
    head :bad_request
  end

  private

  def slack_payload
    @slack_payload ||= JSON.parse(request.raw_post).with_indifferent_access
  end

  def valid_slack_signature?
    signing_secret = GlobalConfigService.load('SLACK_SIGNING_SECRET', nil)
    timestamp = request.headers['X-Slack-Request-Timestamp'].to_s
    provided_signature = request.headers['X-Slack-Signature'].to_s
    return false if signing_secret.blank? || timestamp.blank? || provided_signature.blank?
    return false unless timestamp.match?(/\A\d+\z/)
    return false if (Time.current.to_i - timestamp.to_i).abs > SLACK_SIGNATURE_TOLERANCE

    signature_base = "#{SLACK_SIGNATURE_VERSION}:#{timestamp}:#{request.raw_post}"
    expected_signature = "#{SLACK_SIGNATURE_VERSION}=#{OpenSSL::HMAC.hexdigest('SHA256', signing_secret, signature_base)}"
    provided_signature.bytesize == expected_signature.bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(provided_signature, expected_signature)
  end
end
