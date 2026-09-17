class Telephony::InboundRouteLifecycleJob < ApplicationJob
  class ProcessingFailedError < StandardError; end

  queue_as :telephony_realtime

  def perform(payload, retry_failed: false)
    result = Telephony::EventsIngestionService.new(payload: payload).perform
    raise_failed_event!(payload) if retry_failed

    result
  end

  private

  def raise_failed_event!(payload)
    payload = payload.deep_stringify_keys
    event = Telephony::Event.find_by(account_id: payload['account_id'], event_key: payload['event_key'])
    return unless event&.failed?

    raise ProcessingFailedError, "Telephony event #{event.id} failed: #{event.error_message}"
  end
end
