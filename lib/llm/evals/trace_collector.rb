# frozen_string_literal: true

class Llm::Evals::TraceCollector
  PATTERN = /\Allm\./

  attr_reader :trace_id, :events

  def initialize(trace_id: SecureRandom.uuid, redact_raw_content: false)
    @trace_id = trace_id
    @redact_raw_content = redact_raw_content
    @events = []
  end

  def capture
    subscriber = subscribe!
    Llm::EventBus.with_context(trace_id: trace_id) { yield(self) }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  private

  def subscribe!
    ActiveSupport::Notifications.subscribe(PATTERN) do |name, started, finished, _id, payload|
      capture_notification(name, started, finished, payload)
    end
  end

  def capture_notification(name, started, finished, payload)
    attributes = payload.to_h.with_indifferent_access
    return if attributes[:trace_id].to_s != trace_id

    events << {
      event_name: name,
      started_at: started,
      finished_at: finished,
      duration_ms: duration_ms(started, finished),
      payload: Llm::Monitoring::PayloadSanitizer.call(attributes.to_h, redact_raw_content: @redact_raw_content)
    }
  rescue StandardError => e
    events << {
      event_name: 'llm.trace_collector.error',
      error: true,
      payload: { error_class: e.class.name, error_message: e.message }
    }
  end

  def duration_ms(started, finished)
    ((finished - started) * 1000).round if started && finished
  end
end
