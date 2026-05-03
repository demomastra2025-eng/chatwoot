class Internal::Voice::Ai::BaseController < ApplicationController
  before_action :authenticate_internal_voice!

  rescue_from Telephony::Error, with: :render_telephony_error
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  private

  def authenticate_internal_voice!
    expected_token = internal_voice_token
    provided_tokens = [
      bearer_token,
      request.headers['X-Onelink-Internal-Token'].to_s.presence,
      request.headers['X-Voice-Internal-Token'].to_s.presence
    ].compact

    return if provided_tokens.any? { |provided_token| secure_match?(provided_token, expected_token) }

    render json: { error: 'unauthorized' }, status: :unauthorized
  end

  def internal_voice_token
    ENV.fetch('ONELINK_AI_VOICE_INTERNAL_TOKEN', '').presence || ENV.fetch('AI_VOICE_INTERNAL_TOKEN', '').presence
  end

  def bearer_token
    request.authorization.to_s[/\ABearer (.+)\z/i, 1].to_s.presence
  end

  def secure_match?(provided, expected)
    provided.present? && expected.present? && ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  rescue ArgumentError
    false
  end

  def request_payload
    payload = parsed_json_body.presence || params.to_unsafe_h.except('controller', 'action')
    payload['name'] ||= params[:name] if params[:name].present?
    payload
  end

  def request_event_headers
    {
      event_id: request.headers['X-Event-Id'].to_s.presence,
      idempotency_key: request.headers['X-Idempotency-Key'].to_s.presence,
      event_attempt: request.headers['X-Event-Attempt'].to_s.presence,
      request_id: request.headers['X-Request-Id'].to_s.presence
    }.compact
  end

  def parsed_json_body
    return {} unless request.media_type == 'application/json'
    return {} if request.raw_post.blank?

    JSON.parse(request.raw_post)
  rescue JSON::ParserError
    {}
  end

  def render_telephony_error(error)
    render json: { error: error.code, message: error.message }, status: error.status
  end

  def render_not_found(error)
    render json: { error: 'not_found', message: error.message }, status: :not_found
  end
end
