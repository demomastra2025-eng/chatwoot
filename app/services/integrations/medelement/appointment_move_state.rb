# A MedElement reschedule is a request until the provider answers OK. The appointment row keeps the interval the
# provider last confirmed; this state records the requested interval, the command that carries it and its outcome.
# It never says a move succeeded: the provider's OK replaces the interval on the row at once and removes the state
# (no read-back is awaited, a slower cached server may keep showing the old time for a while). A rejected state is an
# explicit provider rejection; a state that needs reconciliation is an ambiguous answer that no read has confirmed yet.
class Integrations::Medelement::AppointmentMoveState
  ATTRIBUTE_KEY = 'medelement_move_request'.freeze
  PENDING = 'pending'.freeze
  NEEDS_RECONCILIATION = 'needs_reconciliation'.freeze
  REJECTED = 'rejected'.freeze
  STATES = [PENDING, NEEDS_RECONCILIATION, REJECTED].freeze
  OPEN_STATES = [PENDING, NEEDS_RECONCILIATION].freeze
  EVIDENCE_NOT_SENT = 'not_sent'.freeze
  EVIDENCE_PROVIDER_REJECTED = 'provider_rejected'.freeze
  PROVIDER_STATUS_STATES = {
    Integrations::Medelement::AppointmentProviderStatus::PENDING => PENDING,
    Integrations::Medelement::AppointmentProviderStatus::UNKNOWN => NEEDS_RECONCILIATION,
    Integrations::Medelement::AppointmentProviderStatus::FAILED => REJECTED
  }.freeze

  class << self
    def read(source)
      attributes = source.respond_to?(:custom_attributes) ? source.custom_attributes : source
      entry = attributes.to_h[ATTRIBUTE_KEY]
      entry if entry.is_a?(Hash) && entry['state'].in?(STATES)
    end

    def state(source)
      read(source)&.fetch('state')
    end

    def open?(source)
      state(source).in?(OPEN_STATES)
    end

    def rejected?(source)
      state(source) == REJECTED
    end

    # The provider sync status a move state stands for (pending, provider_status_unknown or failed).
    def provider_status_for(state)
      PROVIDER_STATUS_STATES.key(state)
    end

    # Written in the same save that keeps the confirmed interval on the row. The command id is added once the command exists.
    def staged(attributes, confirmed:, requested:)
      attributes.to_h.merge(
        ATTRIBUTE_KEY => {
          'state' => PENDING,
          'confirmed_starts_at' => timestamp(confirmed[:starts_at]), 'confirmed_ends_at' => timestamp(confirmed[:ends_at]),
          'requested_starts_at' => timestamp(requested[:starts_at]), 'requested_ends_at' => timestamp(requested[:ends_at]),
          'requested_at' => timestamp(Time.current)
        }
      )
    end

    # Derives the move state from the provider status projected for a move command. A succeeded move leaves no state.
    def projected(attributes, command:, provider_status:)
      attributes = attributes.to_h
      return attributes.except(ATTRIBUTE_KEY) if provider_status == Integrations::Medelement::AppointmentProviderStatus::SUCCEEDED

      state = PROVIDER_STATUS_STATES[provider_status]
      return attributes if state.blank?

      attributes.merge(ATTRIBUTE_KEY => entry_for(attributes[ATTRIBUTE_KEY], command, state))
    end

    def cleared(attributes)
      attributes.to_h.except(ATTRIBUTE_KEY)
    end

    # A reception import is the provider's own account of the appointment. A rejected request is history that stays visible
    # while the provider still shows the interval the move kept, and stops being true once it shows another one. An open
    # request is never dropped here: the command that carries it decides its outcome.
    def after_provider_import(attributes, starts_at:, ends_at:)
      entry = read(attributes)
      return attributes.to_h unless entry && entry['state'] == REJECTED
      return attributes.to_h if confirmed_interval?(entry, starts_at, ends_at)

      cleared(attributes)
    end

    # The write result is unresolved without a command to read it from: a request still waiting needs reconciliation.
    def flagged(attributes)
      attributes = attributes.to_h
      entry = read(attributes)
      return attributes unless entry && entry['state'] == PENDING

      attributes.merge(ATTRIBUTE_KEY => entry.merge('state' => NEEDS_RECONCILIATION))
    end

    def payload(source)
      entry = read(source)
      return {} if entry.blank?

      { provider_move: {
        state: entry['state'],
        requested_time_confirmed: false,
        needs_reconciliation: entry['state'] == NEEDS_RECONCILIATION,
        command_id: entry['command_id'],
        confirmed_starts_at: entry['confirmed_starts_at'], confirmed_ends_at: entry['confirmed_ends_at'],
        requested_starts_at: entry['requested_starts_at'], requested_ends_at: entry['requested_ends_at'],
        requested_at: entry['requested_at'],
        error_code: entry['error_code'], error_status: entry['error_status'], evidence: entry['evidence']
      }.compact }
    end

    def time(entry, key)
      value = entry.to_h[key]
      Time.iso8601(value) if value.present?
    rescue ArgumentError
      nil
    end

    private

    def confirmed_interval?(entry, starts_at, ends_at)
      time(entry, 'confirmed_starts_at')&.to_i == starts_at&.to_i && time(entry, 'confirmed_ends_at')&.to_i == ends_at&.to_i
    end

    def entry_for(previous, command, state)
      previous = previous.is_a?(Hash) ? previous : {}
      reception = command.request_snapshot.to_h['reception'].to_h
      failure = command.execution_state.to_h['write_failure'].to_h
      {
        'state' => state,
        'command_id' => command.id,
        'confirmed_starts_at' => reception['source_starts_at'].presence || previous['confirmed_starts_at'],
        'confirmed_ends_at' => reception['source_ends_at'].presence || previous['confirmed_ends_at'],
        'requested_starts_at' => reception['destination_starts_at'].presence || previous['requested_starts_at'],
        'requested_ends_at' => reception['destination_ends_at'].presence || previous['requested_ends_at'],
        'requested_at' => previous['requested_at'].presence || timestamp(command.created_at)
      }.merge(outcome_entry(command, failure, state)).compact
    end

    def outcome_entry(command, failure, state)
      return {} if state == PENDING

      {
        'error_code' => failure['code'].presence || command.last_error_code.presence,
        'error_status' => failure['status'] || command.last_error_status,
        'evidence' => (rejection_evidence(command) if state == REJECTED)
      }
    end

    def rejection_evidence(command)
      write_started?(command) ? EVIDENCE_PROVIDER_REJECTED : EVIDENCE_NOT_SENT
    end

    # A move command carries the reception it moves from creation, so only the write phase proves the request was sent.
    def write_started?(command)
      command.execution_state.to_h['write_phase'].present?
    end

    def timestamp(value)
      value&.utc&.iso8601(6)
    end
  end
end
