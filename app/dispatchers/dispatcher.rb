class Dispatcher
  include Singleton

  attr_reader :async_dispatcher, :sync_dispatcher

  def self.dispatch(event_name, timestamp, data, async = false)
    Rails.configuration.dispatcher.dispatch(event_name, timestamp, data, async)
  end

  def initialize
    @sync_dispatcher = SyncDispatcher.new
    @async_dispatcher = AsyncDispatcher.new
  end

  def dispatch(event_name, timestamp, data, _async = false)
    return if reconciled_appointment_event?(event_name)

    @sync_dispatcher.dispatch(event_name, timestamp, data)
    @async_dispatcher.dispatch(event_name, timestamp, data)
  end

  def load_listeners
    @sync_dispatcher.load_listeners
    @async_dispatcher.load_listeners
  end

  private

  # A status corrected from MedElement for a past visit (Current.with_medelement_reconciliation) is a data correction:
  # no listener sees it, so no automation rule, CRM re-evaluation or patient message reacts to it. The flag is only set
  # around that import, and only appointment events are held back.
  def reconciled_appointment_event?(event_name)
    Current.medelement_reconciliation && event_name.to_s.start_with?('appointment.')
  end
end
