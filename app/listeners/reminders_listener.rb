class RemindersListener < BaseListener
  def message_created(event)
    Reminders::AutoCancelOnIncomingService.new(message: event.data[:message]).perform
  end
end
