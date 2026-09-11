# frozen_string_literal: true

class Telephony::BinotelEventsController < ActionController::API
  before_action :authenticate_token!

  def create
    payload = Telephony::Binotel::EventAdapter.new(request_payload).payload
    process_payload(payload)
    render json: { status: 'success' }
  rescue ActiveJob::EnqueueError, Redis::BaseError, RedisClient::Error => e
    handle_queue_fallback(payload, e)
  rescue StandardError => e
    handle_error(e)
  end

  private

  attr_reader :binotel_channel

  def process_payload(payload)
    if payload.present?
      Telephony::InboundRouteLifecycleJob.perform_later(payload, retry_failed: true)
    else
      Rails.logger.warn("BINOTEL_EVENT_IGNORED request_id=#{request.request_id} reason=invalid_or_unsupported_payload")
    end
  end

  def handle_queue_fallback(payload, error)
    Rails.logger.warn("BINOTEL_EVENT_QUEUE_FALLBACK request_id=#{request.request_id} error=#{error.class.name}: #{error.message}")
    Telephony::EventsIngestionService.new(payload: payload).perform if payload.present?
    render json: { status: 'success' }
  end

  def handle_error(error)
    Rails.logger.error("BINOTEL_EVENT_ERROR request_id=#{request.request_id} error=#{error.class.name}: #{error.message}")
    render json: { status: 'error' }, status: :internal_server_error
  end

  def request_payload
    config = binotel_channel.provider_config_hash
    params.to_unsafe_h.except('controller', 'action', 'token').merge(
      'chatwoot_account_id' => binotel_channel.account_id,
      'chatwoot_inbox_id' => binotel_channel.inbox&.id,
      'number_ref' => config['number_ref'],
      'ingress_number' => config['ingress_number'].presence || binotel_channel.phone_number,
      'received_at' => Time.current.iso8601,
      'request_id' => request.request_id
    ).compact
  end

  def authenticate_token!
    token = params[:token].to_s
    @binotel_channel = binotel_channel_for_token(token)
    return if @binotel_channel.present?

    render json: { status: 'error' }, status: :unauthorized
  end

  def binotel_channel_for_token(token)
    return if token.blank?

    channels = Channel::Voice
               .where(provider: 'binotel')
               .where(
                 "provider_config ->> 'binotel_events_webhook_token' = :token OR " \
                 "(COALESCE(provider_config ->> 'binotel_events_webhook_token', '') = '' AND " \
                 "provider_config ->> 'binotel_webhook_token' = :token)",
                 token: token
               )
               .limit(2)
               .to_a
    channels.first if channels.one?
  end
end
