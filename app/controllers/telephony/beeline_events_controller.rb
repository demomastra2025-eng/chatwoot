# frozen_string_literal: true

class Telephony::BeelineEventsController < ActionController::API
  before_action :authenticate_token!

  def create
    return render json: { ok: true, status: 'verified' }, status: :ok if verification_request?

    adapter = Telephony::Beeline::EventAdapter.new(params: params, inbox: @inbox, raw_body: request.raw_post)
    payload = adapter.call
    return render_ignored_event if payload.blank?

    process_beeline_payload(adapter, payload)
  rescue StandardError => e
    log_processing_error(e)
    render json: { ok: false, error: 'Webhook processing failed' }, status: :unprocessable_entity
  end

  private

  def render_ignored_event
    render json: { ok: true, ignored: true, reason: 'unsupported_or_incomplete_event' }, status: :ok
  end

  def process_beeline_payload(adapter, payload)
    return render_matched_event(payload) if adapter.correlation_status == :matched

    render_unmatched_event(payload)
  end

  def render_matched_event(payload)
    call_session = Telephony::EventsIngestionService.new(payload: payload).perform
    render json: {
      ok: true,
      correlated: true,
      call_ref: call_session&.external_call_ref || payload['call_ref'],
      status: call_session&.status || payload['status']
    }, status: :ok
  end

  def render_unmatched_event(payload)
    fallback_payload = Telephony::Beeline::TerminalFallbackAdapter.new(payload: payload).call
    return render_deferred_event(payload) if fallback_payload.blank?

    enqueue_or_ingest_fallback!(fallback_payload)
    render json: {
      ok: true,
      correlated: false,
      terminal_fallback: true,
      call_ref: fallback_payload['call_ref'],
      status: fallback_payload['status']
    }, status: :ok
  end

  def render_deferred_event(payload)
    persist_reconciliation_only_event(payload)
    render json: { ok: true, correlated: false, deferred: true, status: payload['status'] }, status: :ok
  end

  def log_processing_error(error)
    Rails.logger.error(
      "TELEPHONY_BEELINE_EVENT_ERROR inbox_id=#{@inbox&.id} request_id=#{request.request_id} " \
      "error_class=#{error.class.name} message=#{error.message}"
    )
  end

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

    save_reconciliation_event!(account, payload)
  rescue ActiveRecord::RecordNotUnique
    retry
  rescue StandardError => e
    Rails.logger.warn("TELEPHONY_BEELINE_RECONCILIATION_EVENT_SAVE_FAILED error=#{e.class.name}: #{e.message}")
  end

  def save_reconciliation_event!(account, payload)
    event = account.telephony_events.find_or_initialize_by(event_key: payload['event_key'])
    event.event_type = payload['event'] || 'unknown'
    event.payload = reconciliation_payload(payload)
    event.status = 'processed'
    event.processed_at ||= Time.current
    event.save!
  end

  def reconciliation_payload(payload)
    metadata = payload['metadata'].is_a?(Hash) ? payload['metadata'] : {}
    payload.merge('metadata' => metadata.merge('beeline_webhook_mode' => 'reconciliation_only', 'beeline_webhook_unmatched' => true))
  end

  def authenticate_token!
    provided_token = params[:token].to_s.strip
    return render_unauthorized if provided_token.blank?

    @inbox = find_matching_voice_channel(provided_token)&.inbox
    render_unauthorized if @inbox.blank?
  end

  def render_unauthorized
    render json: { ok: false, error: 'Unauthorized' }, status: :unauthorized
  end

  def find_matching_voice_channel(provided_token)
    find_configured_beeline_channel(provided_token) || find_env_token_beeline_channel(provided_token)
  end

  def find_configured_beeline_channel(provided_token)
    Channel::Voice.where(provider: 'beeline').includes(:inbox).find do |channel|
      expected = channel_webhook_token(channel.provider_config_hash)
      expected.present? && secure_match?(provided_token, expected)
    end
  end

  def channel_webhook_token(cfg)
    cfg['beeline_events_webhook_token'].to_s.strip.presence || cfg['beeline_webhook_token'].to_s.strip.presence
  end

  def find_env_token_beeline_channel(provided_token)
    env_token = ENV.fetch('BEELINE_WEBHOOK_TOKEN', '').to_s.strip.presence ||
                ENV.fetch('TELEPHONY_BEELINE_WEBHOOK_TOKEN', '').to_s.strip.presence
    return nil unless env_token.present? && secure_match?(provided_token, env_token)

    channels = Channel::Voice.where(provider: 'beeline').includes(:inbox).limit(2).to_a
    channels.first if channels.one?
  end

  def secure_match?(provided, expected)
    return false if provided.blank? || expected.blank?
    return false unless provided.bytesize == expected.bytesize

    ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end
end
