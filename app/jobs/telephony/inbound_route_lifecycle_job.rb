class Telephony::InboundRouteLifecycleJob < ApplicationJob
  queue_as :high

  def perform(payload)
    Telephony::EventsIngestionService.new(payload: payload).perform
  end
end
