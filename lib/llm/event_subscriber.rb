# frozen_string_literal: true

class Llm::EventSubscriber
  PATTERN = /\Allm\./
  INSTALL_MUTEX = Mutex.new

  class << self
    def install!(previous_subscriber: nil)
      INSTALL_MUTEX.synchronize do
        unsubscribe(previous_subscriber)
        unsubscribe(@subscriber) unless @subscriber.equal?(previous_subscriber)
        @subscriber = ActiveSupport::Notifications.subscribe(PATTERN) do |name, started, finished, _id, payload|
          notification = {
            event_name: name,
            started_at: started,
            finished_at: finished,
            payload: payload
          }
          Llm::Monitoring::EventRecorder.record_notification(**notification)
          export_to_otel(notification)
        end
      end
    end

    def export_to_otel(notification)
      Llm::Monitoring::OtelEventExporter.export_notification(**notification)
    rescue StandardError => e
      Rails.logger.warn("[Llm::EventSubscriber] Failed to export OTel event #{notification[:event_name]}: #{e.class}: #{e.message}")
      nil
    end

    def uninstall!
      return unless defined?(@subscriber) && @subscriber.present?

      unsubscribe(@subscriber)
      @subscriber = nil
    end

    private

    def unsubscribe(subscriber)
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber.present?
    end
  end
end
