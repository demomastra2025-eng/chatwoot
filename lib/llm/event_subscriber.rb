# frozen_string_literal: true

require 'set'

class Llm::EventSubscriber
  PATTERN = /\Allm\./
  INSTALL_MUTEX = Mutex.new

  class << self
    def install!
      INSTALL_MUTEX.synchronize do
        uninstall!
        @subscriber = ActiveSupport::Notifications.subscribe(PATTERN) do |name, started, finished, _id, payload|
          Llm::Monitoring::EventRecorder.record_notification(
            event_name: name,
            started_at: started,
            finished_at: finished,
            payload: payload
          )
        end
      end
    end

    def uninstall!
      return unless defined?(@subscriber) && @subscriber.present?

      ActiveSupport::Notifications.unsubscribe(@subscriber)
      @subscriber = nil
    end
  end
end
