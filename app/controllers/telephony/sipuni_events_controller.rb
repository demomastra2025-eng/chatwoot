# frozen_string_literal: true

class Telephony::SipuniEventsController < ActionController::API
  before_action :authenticate_token!

  def create
    payload = Telephony::Sipuni::EventAdapter.new(request_payload).payload
    if payload.present?
      route_fast_incoming_call(payload) if fast_incoming_start_event?(payload)
      lifecycle_status = process_lifecycle_event(payload)
      render json: { success: true, status: lifecycle_status }
    else
      Rails.logger.warn("SIPUNI_EVENT_IGNORED request_id=#{request.request_id} reason=unresolved_or_missing_call_id")
      render json: { success: true, status: 'ignored' }
    end
  rescue ActiveJob::EnqueueError, Redis::BaseError, RedisClient::Error => e
    Rails.logger.warn("SIPUNI_EVENT_QUEUE_FALLBACK request_id=#{request.request_id} error=#{e.class.name}: #{e.message}")
    Telephony::EventsIngestionService.new(payload: payload).perform if payload.present?
    render json: { success: true, status: 'processed' }
  rescue StandardError => e
    Rails.logger.error("SIPUNI_EVENT_ERROR request_id=#{request.request_id} error=#{e.class.name}: #{e.message}")
    render json: { success: true, status: 'accepted_with_error' }
  end

  private

  attr_reader :sipuni_channel

  def request_payload
    payload = params.to_unsafe_h.except('controller', 'action', 'token').merge(
      'received_at' => Time.current.iso8601,
      'request_id' => request.request_id
    )

    return payload if sipuni_channel.blank?

    config = sipuni_channel.provider_config_hash.with_indifferent_access
    payload['chatwoot_account_id'] ||= sipuni_channel.account_id
    payload['chatwoot_inbox_id'] ||= sipuni_channel.inbox&.id
    payload['number_ref'] ||= config[:number_ref]
    payload
  end

  def fast_incoming_start_event?(payload)
    payload_value(payload, :provider) == 'sipuni' &&
      payload_value(payload, :direction) == 'inbound' &&
      payload_value(payload, :event) == 'session_started'
  end

  def fast_terminal_event?(payload)
    payload_value(payload, :provider) == 'sipuni' &&
      Telephony::CallSession::TERMINAL_STATUSES.include?(payload_value(payload, :status).to_s)
  end

  def process_lifecycle_event(payload)
    return enqueue_lifecycle_event(payload) unless fast_terminal_event?(payload)

    Telephony::EventsIngestionService.new(payload: payload).perform
    'processed'
  rescue StandardError => e
    Rails.logger.warn(
      "SIPUNI_INLINE_LIFECYCLE_FAILED request_id=#{request.request_id} " \
      "call_ref=#{payload_value(payload, :call_ref)} error=#{e.class.name}: #{e.message}"
    )
    enqueue_lifecycle_event(payload)
  end

  def enqueue_lifecycle_event(payload)
    Telephony::InboundRouteLifecycleJob.perform_later(payload)
    'accepted'
  end

  def route_fast_incoming_call(payload)
    Telephony::InboundRoutingService.new(payload: payload).perform
  rescue StandardError => e
    Rails.logger.warn(
      "SIPUNI_FAST_INCOMING_ROUTE_FAILED request_id=#{request.request_id} " \
      "call_ref=#{payload_value(payload, :call_ref)} error=#{e.class.name}: #{e.message}"
    )
  end

  def payload_value(payload, key)
    payload[key] || payload[key.to_s]
  end

  def authenticate_token!
    token = params[:token].to_s
    if token.blank?
      render json: { success: false, error: 'unauthorized' }, status: :unauthorized
      return
    end

    return if token_matches?(token, legacy_expected_token)

    @sipuni_channel = sipuni_channel_for_token(token)
    return if @sipuni_channel.present?

    if legacy_expected_token.blank? && !channel_tokens_configured?
      render json: { success: false, error: 'webhook_token_not_configured' }, status: :service_unavailable
      return
    end

    render json: { success: false, error: 'unauthorized' }, status: :unauthorized
  end

  def legacy_expected_token
    ENV.fetch('SIPUNI_WEBHOOK_TOKEN', '').presence ||
      ENV.fetch('TELEPHONY_SIPUNI_WEBHOOK_TOKEN', '').presence
  end

  def token_matches?(token, expected_token)
    return false if token.blank? || expected_token.blank?
    return false unless token.bytesize == expected_token.bytesize

    ActiveSupport::SecurityUtils.secure_compare(token, expected_token)
  end

  def sipuni_channel_for_token(token)
    channels = Channel::Voice
               .where(provider: 'sipuni')
               .where(
                 "provider_config ->> 'sipuni_events_webhook_token' = :token OR " \
                 "provider_config ->> 'sipuni_webhook_token' = :token",
                 token: token
               )
               .limit(2)
               .to_a
    return unless channels.one?

    channels.first
  end

  def channel_tokens_configured?
    Channel::Voice
      .where(provider: 'sipuni')
      .where(
        "NULLIF(provider_config ->> 'sipuni_events_webhook_token', '') IS NOT NULL OR " \
        "NULLIF(provider_config ->> 'sipuni_webhook_token', '') IS NOT NULL"
      )
      .exists?
  end
end
