# frozen_string_literal: true

class Telephony::SipuniEventsController < ActionController::API
  before_action :authenticate_token!

  def create
    payload = Telephony::Sipuni::EventAdapter.new(request_payload).payload
    render json: response_for_payload(payload)
  rescue ActiveJob::EnqueueError, Redis::BaseError, RedisClient::Error => e
    handle_queue_fallback(payload, e)
  rescue StandardError => e
    handle_error(e)
  end

  private

  attr_reader :sipuni_channel

  def response_for_payload(payload)
    return { success: true, status: lifecycle_status_for(payload) } if payload.present?

    Rails.logger.warn("SIPUNI_EVENT_IGNORED request_id=#{request.request_id} reason=unresolved_or_missing_call_id")
    { success: true, status: 'ignored' }
  end

  def lifecycle_status_for(payload)
    route_fast_incoming_call(payload) if route_fast_incoming_start_event?(payload)
    process_lifecycle_event(payload)
  end

  def handle_queue_fallback(payload, error)
    Rails.logger.warn("SIPUNI_EVENT_QUEUE_FALLBACK request_id=#{request.request_id} error=#{error.class.name}: #{error.message}")
    Telephony::EventsIngestionService.new(payload: payload).perform if payload.present?
    render json: { success: true, status: 'processed' }
  end

  def handle_error(error)
    Rails.logger.error("SIPUNI_EVENT_ERROR request_id=#{request.request_id} error=#{error.class.name}: #{error.message}")
    render json: { success: true, status: 'accepted_with_error' }
  end

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

  def route_fast_incoming_start_event?(payload)
    fast_incoming_start_event?(payload) && !sipuni_browser_webphone_reconciliation_only?(payload)
  end

  def fast_incoming_start_event?(payload)
    payload_value(payload, :provider) == 'sipuni' &&
      payload_value(payload, :direction) == 'inbound' &&
      payload_value(payload, :event) == 'session_started'
  end

  def process_lifecycle_event(payload)
    return persist_reconciliation_only_event(payload) if sipuni_browser_webphone_unmatched?(payload)

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

  def persist_reconciliation_only_event(payload)
    account = Account.find_by(id: payload_value(payload, :account_id))
    return 'ignored' if account.blank?

    event = account.telephony_events.find_or_initialize_by(event_key: payload_value(payload, :event_key))
    event.event_type = payload_value(payload, :event) || 'unknown'
    event.payload = reconciliation_only_payload(payload)
    event.status = 'processed'
    event.processed_at ||= Time.current
    event.save!
    'reconciliation_pending'
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def reconciliation_only_payload(payload)
    payload = payload.deep_stringify_keys.deep_dup
    metadata = payload['metadata'].is_a?(Hash) ? payload['metadata'] : {}
    payload['metadata'] = metadata.merge(
      'sipuni_webhook_mode' => 'reconciliation_only',
      'sipuni_webhook_unmatched' => true
    )
    payload
  end

  def sipuni_browser_webphone_unmatched?(payload)
    return false unless sipuni_browser_webphone_reconciliation_only?(payload)

    !sipuni_reconciles_existing_call_session?(payload)
  end

  def sipuni_browser_webphone_reconciliation_only?(payload)
    payload_value(payload, :provider) == 'sipuni' &&
      payload_value(payload, :direction) == 'inbound' &&
      sipuni_browser_webphone_inbox?(payload)
  end

  def sipuni_browser_webphone_inbox?(payload)
    inbox_id = payload_value(payload, :inbox_id)
    return false if inbox_id.blank?

    Inbox.find_by(id: inbox_id)&.telephony_sip_profiles&.exists?(
      availability_mode: 'browser_webphone'
    ) || false
  end

  def sipuni_reconciles_existing_call_session?(payload)
    account = Account.find_by(id: payload_value(payload, :account_id))
    return false if account.blank?

    call_ref = payload_value(payload, :call_ref).to_s
    provider_call_sid = payload_value(payload, :provider_call_sid).to_s
    return true if call_ref.start_with?('sipuni:janus:') &&
                   account.telephony_call_sessions.exists?(external_call_ref: call_ref)
    return true if provider_call_sid.present? &&
                   account.telephony_call_sessions.exists?(provider_call_sid: provider_call_sid)

    call_ref.present? && account.telephony_call_sessions.exists?(external_call_ref: call_ref)
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
