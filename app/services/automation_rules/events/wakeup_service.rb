class AutomationRules::Events::WakeupService
  BATCH_SIZE = 100
  RESERVATION_DURATION = 5.minutes
  RETRY_DELAY = 1.minute

  Reservation = Data.define(:event_id, :reserved_until)

  class << self
    def enqueue_one!(event_id)
      reservation = reserve(limit: 1, event_id: event_id).first
      return if reservation.blank?

      enqueue!(reservation)
    end

    def enqueue_batch!
      reserve(limit: BATCH_SIZE).each do |reservation|
        enqueue!(reservation)
      rescue StandardError => e
        Rails.logger.error("Automation event #{reservation.event_id} enqueue failed: #{e.class}: #{e.message}")
      end
    end

    private

    def reserve(limit:, event_id: nil)
      AutomationEvent.transaction do
        scope = AutomationEvent.ready
        scope = scope.where(id: event_id) if event_id.present?
        scope.lock('FOR UPDATE SKIP LOCKED').limit(limit).map do |event|
          reserved_until = RESERVATION_DURATION.from_now
          event.update!(
            status: event.processing? ? 'retrying' : event.status,
            lease_owner: nil,
            lease_expires_at: nil,
            next_attempt_at: reserved_until
          )
          Reservation.new(event.id, reserved_until)
        end
      end
    end

    def enqueue!(reservation)
      AutomationRules::PublishEventJob.perform_later!(reservation.event_id, reservation.reserved_until.iso8601(6))
    rescue StandardError => e
      release_after_failure!(reservation, e)
      raise
    end

    def release_after_failure!(reservation, error)
      AutomationEvent.transaction do
        event = AutomationEvent.lock.find_by(id: reservation.event_id)
        return if event.blank? || event.next_attempt_at.iso8601(6) != reservation.reserved_until.iso8601(6)

        event.update!(
          status: 'retrying',
          next_attempt_at: RETRY_DELAY.from_now,
          last_error: "wakeup enqueue failed: #{error.class}: #{error.message}".first(2000)
        )
      end
    end
  end
end
