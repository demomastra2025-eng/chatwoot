# frozen_string_literal: true

class Telephony::BeelineEventsController < ActionController::API
  before_action :authenticate_token!

  def create
    if verification_request?
      render json: { ok: true, status: 'verified' }, status: :ok
      return
    end

    adapter = Telephony::Beeline::EventAdapter.new(
      params: params,
      inbox: @inbox,
      raw_body: request.raw_post
    )
    payload = adapter.call

    if payload.blank?
      render json: { ok: true, ignored: true, reason: 'unsupported_or_incomplete_event' }, status: :ok
      return
    end

    if adapter.correlation_status == :matched
      call_session = Telephony::EventsIngestionService.new(payload: payload).perform
      render json: {
        ok: true,
        correlated: true,
        call_ref: call_session&.external_call_ref || payload['call_ref'],
        status: call_session&.status || payload['status']
      }, status: :ok
      return
    end

    fallback_payload = Telephony::Beeline::TerminalFallbackAdapter.new(payload: payload).call
    if fallback_payload.present?
      enqueue_or_ingest_fallback!(fallback_payload)
      render json: {
        ok: true,
        correlated: false,
        terminal_fallback: true,
        call_ref: fallback_payload['call_ref'],
        status: fallback_payload['status']
      }, status: :ok
    else
      persist_reconciliation_only_event(payload)
      render json: {
        ok: true,
        correlated: false,
        deferred: true,
        status: payload['status']
      }, status: :ok
    end
  rescue StandardError => e
    Rails.logger.error(
      "TELEPHONY_BEELINE_EVENT_ERROR inbox_id=#{@inbox&.id} request_id=#{request.request_id} " \
      "error_class=#{e.class.name} message=#{e.message}"
    )
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def verification_request?
    return true if request.get? || request.head?

    request.raw_post.to_s.strip.blank? &&
      params.to_unsafe_h.except('controller', 'action', 'token', 'format').blank?
  end

  def enqueue_or_ingest_fallback!(fallback_payload)
    Telephony::InboundRouteLifecycleJob.perform_later(fallback_payload, retry_failed: true)
  rescue ActiveJob::EnqueueError, Redis::BaseError, RedisClient::Error => e
    Rails.logger.warn(
      "TELEPHONY_BEELINE_EVENT_QUEUE_FALLBACK inbox_id=#{@inbox&.id} request_id=#{request.request_id} " \
      "error=#{e.class.name}: #{e.message}"
    )
    Telephony::EventsIngestionService.new(payload: fallback_payload).perform
  end

  def persist_reconciliation_only_event(payload)
    account = @inbox&.account
    return if account.blank? || payload['event_key'].blank?

    event = account.telephony_events.find_or_initialize_by(event_key: payload['event_key'])
    event.event_type = payload['event'] || 'unknown'
    metadata = payload['metadata'].is_a?(Hash) ? payload['metadata'] : {}
    event.payload = payload.merge(
      'metadata' => metadata.merge(
        'beeline_webhook_mode' => 'reconciliation_only',
        'beeline_webhook_unmatched' => true
      )
    )
    event.status = 'processed'
    event.processed_at ||= Time.current
    event.save!
  rescue ActiveRecord::RecordNotUnique
    retry
  rescue StandardError => e
    Rails.logger.warn("TELEPHONY_BEELINE_RECONCILIATION_EVENT_SAVE_FAILED error=#{e.class.name}: #{e.message}")
  end

  def authenticate_token!
    provided_token = params[:token].to_s.strip
    if provided_token.blank?
      render json: { ok: false, error: 'Unauthorized' }, status: :unauthorized
      return
    end

    voice_channel = find_matching_voice_channel(provided_token)
    @inbox = voice_channel&.inbox

    return if @inbox.present?

    render json: { ok: false, error: 'Unauthorized' }, status: :unauthorized
  end

  def find_matching_voice_channel(provided_token)
    matched = Channel::Voice.where(provider: 'beeline').includes(:inbox).find do |channel|
      cfg = channel.provider_config_hash
      expected = cfg['beeline_events_webhook_token'].to_s.strip.presence ||
                 cfg['beeline_webhook_token'].to_s.strip.presence
      next false if expected.blank?

      secure_match?(provided_token, expected)
    end
    return matched if matched.present?

    env_token = ENV.fetch('BEELINE_WEBHOOK_TOKEN', '').to_s.strip.presence ||
                ENV.fetch('TELEPHONY_BEELINE_WEBHOOK_TOKEN', '').to_s.strip.presence
    if env_token.present? && secure_match?(provided_token, env_token)
      channels = Channel::Voice.where(provider: 'beeline').includes(:inbox).limit(2).to_a
      return channels.first if channels.one?
    end

    nil
  end

  def secure_match?(provided, expected)
    return false if provided.blank? || expected.blank?
    return false unless provided.bytesize == expected.bytesize

    ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end
end
