class Telephony::InboundRouteLifecycleJob < ApplicationJob
  queue_as :telephony_realtime

  def perform(payload)
    Telephony::EventsIngestionService.new(payload: payload).perform
  rescue Telephony::Error => e
    Rails.logger.warn(
      '[TELEPHONY] Discarding invalid lifecycle event: ' \
      "code=#{e.code} account_id=#{payload_value(payload, 'account_id', 'accountId')} " \
      "call_ref=#{payload_value(payload, 'call_ref', 'callRef', 'call_sid', 'callSid')} " \
      "event_key=#{payload_value(payload, 'event_key', 'eventKey', 'idempotency_key', 'idempotencyKey')}"
    )
    nil
  end

  private

  def payload_value(payload, *keys)
    payload = payload.to_h
    keys.each do |key|
      value = payload[key] || payload[key.to_s]
      return value if value.present?
    end

    nil
  end
end
