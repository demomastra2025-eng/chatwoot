class Telephony::InboundRouteLifecycleJob < ApplicationJob
  queue_as :telephony_realtime

  def perform(payload)
    Telephony::EventsIngestionService.new(payload: payload).perform
  end
end
