class AutomationRules::Events::Publisher
  LEASE_DURATION = 5.minutes
  MAX_ATTEMPTS = 5

  Claim = Data.define(:event, :lease_owner)

  def initialize(event_id = nil, worker_id: SecureRandom.uuid, reservation_token: nil)
    @event_id = event_id
    @worker_id = worker_id
    @reservation_token = reservation_token
  end

  def perform
    claim = claim!
    return if claim.blank?

    deliver(claim.event)
    complete!(claim)
  rescue StandardError => e
    fail_claim!(claim, e) if claim.present?
    raise
  end

  def claim!
    AutomationEvent.transaction do
      event = claim_scope.lock('FOR UPDATE SKIP LOCKED').first
      next if event.blank?

      event.update!(
        status: 'processing',
        attempts: event.attempts + 1,
        lease_owner: worker_id,
        lease_expires_at: LEASE_DURATION.from_now,
        last_error: nil
      )
      Claim.new(event, worker_id)
    end
  end

  private

  attr_reader :event_id, :worker_id, :reservation_token

  def claim_scope
    return AutomationEvent.ready if event_id.blank?
    return AutomationEvent.ready.where(id: event_id) if reservation_token.blank?

    AutomationEvent.where(id: event_id, status: %w[pending retrying], next_attempt_at: Time.zone.parse(reservation_token))
  end

  # A2 is capture-only. Matching and execution cut over in later slices; consuming
  # the durable envelope here must not invoke the legacy listeners a second time.
  def deliver(_event)
    true
  end

  def complete!(claim)
    transition_claim(claim) do |event|
      event.update!(status: 'completed', lease_owner: nil, lease_expires_at: nil, last_error: nil)
    end
  end

  def fail_claim!(claim, error)
    transition_claim(claim) do |event|
      attributes = {
        lease_owner: nil,
        lease_expires_at: nil,
        last_error: "#{error.class}: #{error.message}".first(2000)
      }
      if event.attempts >= MAX_ATTEMPTS
        attributes[:status] = 'dead'
        attributes[:dead_at] = Time.current
      else
        attributes[:status] = 'retrying'
        attributes[:next_attempt_at] = retry_delay(event.attempts).from_now
      end
      event.update!(attributes)
    end
  end

  def transition_claim(claim)
    AutomationEvent.transaction do
      event = AutomationEvent.lock.find(claim.event.id)
      return unless event.processing? && event.lease_owner == claim.lease_owner

      yield event
    end
  end

  def retry_delay(attempt)
    [1.minute * (2**(attempt - 1).clamp(0, 6)), 1.hour].min
  end
end
