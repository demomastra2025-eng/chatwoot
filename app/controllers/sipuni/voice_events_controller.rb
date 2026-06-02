require 'digest'

class Sipuni::VoiceEventsController < ApplicationController
  before_action :set_inbox!
  before_action :authenticate_webhook!

  def create
    normalized_payload = Sipuni::Events::Normalizer.new(params: webhook_params, inbox: inbox).perform
    call_session = Telephony::EventsIngestionService.new(payload: normalized_payload).perform

    render json: {
      success: true,
      call_ref: call_session.external_call_ref,
      conversation_id: call_session.conversation&.display_id
    }.compact
  rescue Telephony::Error => e
    Rails.logger.warn(
      "SIPUNI_VOICE_EVENT_ERROR inbox_id=#{inbox&.id} code=#{e.code} message=#{e.message}"
    )
    render json: { success: false, code: e.code, error: e.message }, status: e.status
  rescue StandardError => e
    Rails.logger.error(
      "SIPUNI_VOICE_EVENT_ERROR inbox_id=#{inbox&.id} error_class=#{e.class.name} message=#{e.message}"
    )
    render json: { success: false, error: 'Unable to process Sipuni event' }, status: :unprocessable_content
  end

  private

  attr_reader :inbox

  delegate :channel, to: :inbox, prefix: true

  def set_inbox!
    @inbox = Inbox.includes(:channel).find_by(id: params[:inbox_id])
    return if @inbox&.channel.is_a?(Channel::Voice) && inbox_channel.provider == 'sipuni'

    render json: { success: false, error: 'Sipuni voice inbox not found' }, status: :not_found
  end

  def authenticate_webhook!
    expected_token = inbox_channel.provider_config_hash.with_indifferent_access[:webhook_token].to_s
    return if provided_tokens.any? { |provided_token| secure_match?(provided_token, expected_token) }

    render json: { success: false, error: 'Unauthorized Sipuni webhook' }, status: :unauthorized
  end

  def webhook_params
    params.to_unsafe_h.except('controller', 'action', 'format', 'inbox_id', 'token', 'webhook_token')
  end

  def provided_tokens
    [
      params[:token],
      params[:webhook_token],
      request.headers['X-Sipuni-Webhook-Token'],
      bearer_token
    ].compact_blank.map(&:to_s)
  end

  def bearer_token
    request.authorization.to_s[/\ABearer (.+)\z/i, 1].to_s.presence
  end

  def secure_match?(provided, expected)
    return false if provided.blank? || expected.blank?

    provided_digest = Digest::SHA256.hexdigest(provided.to_s)
    expected_digest = Digest::SHA256.hexdigest(expected.to_s)
    ActiveSupport::SecurityUtils.secure_compare(provided_digest, expected_digest)
  end
end
