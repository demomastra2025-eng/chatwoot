# MedElement answers a reschedule with OK and the change applies a little later on clinics that read from a slower
# cached server, so a reception import in that window can still show the interval the reception had before the move.
# That read is stale, not a correction: the import must not put the old time back over the move the provider accepted.
# The window is bounded, after it the provider's own data is the truth again.
class Integrations::Medelement::AcknowledgedMoveWindow
  DEFAULT_WINDOW = 30.minutes

  class << self
    def stale_read?(appointment, starts_at:, ends_at:, now: Time.current, window: DEFAULT_WINDOW)
      return false unless appointment.persisted? && starts_at.present? && ends_at.present?

      command = latest_acknowledged_move(appointment, since: now - window)
      return false if command.blank?

      interval = command.request_snapshot.to_h['reception'].to_h
      provider = [starts_at, ends_at]
      same_interval?(provider, interval, 'source') && !same_interval?(provider, interval, 'destination')
    end

    private

    def latest_acknowledged_move(appointment, since:)
      Integrations::Medelement::ProviderCommand
        .where(account_id: appointment.account_id, appointment_id: appointment.id, operation: 'move_reception', status: 'succeeded')
        .where(executed_at: since..)
        .order(executed_at: :desc, id: :desc)
        .first
    end

    def same_interval?(provider, reception, prefix)
      candidate = [time(reception["#{prefix}_starts_at"]), time(reception["#{prefix}_ends_at"])]
      candidate.all?(&:present?) && provider.map(&:to_i) == candidate.map(&:to_i)
    end

    def time(value)
      Time.iso8601(value.to_s) if value.present?
    rescue ArgumentError
      nil
    end
  end
end
