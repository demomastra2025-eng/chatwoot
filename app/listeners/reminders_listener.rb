class RemindersListener < BaseListener
  def message_created(event)
    Reminders::AutoCancelOnIncomingService.new(
      message: event.data[:message],
      event_timestamp: event.timestamp
    ).perform
  end

  def message_updated(event)
    Reminders::PostDeliveryActionService.new(message: event.data[:message]).perform
  end
end
