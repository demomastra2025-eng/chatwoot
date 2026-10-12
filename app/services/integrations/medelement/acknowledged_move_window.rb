# MedElement answers a write with OK and the change applies a little later on clinics that read from a slower cached
# server, so a read in that window can still show what was there before the write (or nothing yet for a new reception).
# That read is stale, not a correction: an import must not put the old time back over a move the provider accepted, and a
# command built on the accepted state must not be refused because the cache has not caught up.
# The window is bounded, after it the provider's own data is the truth again.
class Integrations::Medelement::AcknowledgedMoveWindow
  DEFAULT_WINDOW = 30.minutes
  ACKNOWLEDGED_OPERATIONS = %w[create_reception move_reception].freeze

  class << self
    # The provider interval is a stale read when it is where an accepted move took the reception from. It does not depend on
    # what the appointment's last provider operation was: a cancellation sent after the move projects its own operation onto
    # the appointment, and its own stale-read check still has to recognise the pre-move interval.
    def stale_read?(appointment, starts_at:, ends_at:, now: Time.current, window: DEFAULT_WINDOW)
      return false unless appointment.persisted? && starts_at.present? && ends_at.present?

      provider = [starts_at, ends_at]
      # The provider agrees with the calendar: there is nothing to hold back, and no query is spent on the usual imported row.
      return false if same_pair?(provider, [appointment.starts_at, appointment.ends_at])

      acknowledged_moves(appointment, since: now - window).any? do |command|
        interval = command.request_snapshot.to_h['reception'].to_h
        same_interval?(provider, interval, 'source') && !same_interval?(provider, interval, 'destination')
      end
    end

    # The latest create or move of this appointment that MedElement answered OK to inside the window, or nil.
    def latest_acknowledged_write(appointment, now: Time.current, window: DEFAULT_WINDOW)
      return unless appointment&.persisted?

      Integrations::Medelement::ProviderCommand
        .where(account_id: appointment.account_id, appointment_id: appointment.id, operation: ACKNOWLEDGED_OPERATIONS, status: 'succeeded')
        .where(executed_at: (now - window)..)
        .order(executed_at: :desc, id: :desc)
        .first
    end

    private

    # Every move inside the window counts: after A to B and B to C a cached read can still show A.
    def acknowledged_moves(appointment, since:)
      Integrations::Medelement::ProviderCommand
        .where(account_id: appointment.account_id, appointment_id: appointment.id, operation: 'move_reception', status: 'succeeded')
        .where(executed_at: since..)
        .order(executed_at: :desc, id: :desc)
        .to_a
    end

    def same_interval?(provider, reception, prefix)
      same_pair?(provider, [time(reception["#{prefix}_starts_at"]), time(reception["#{prefix}_ends_at"])])
    end

    def same_pair?(first, second)
      first.all?(&:present?) && second.all?(&:present?) && first.map(&:to_i) == second.map(&:to_i)
    end

    def time(value)
      Time.iso8601(value.to_s) if value.present?
    rescue ArgumentError
      nil
    end
  end
end
