class Integrations::Medelement::ProviderCommands::ReconciliationLifecycle
  CLAIM_TOKEN_KEY = 'reconciliation_claim_token'.freeze
  CLAIMED_AT_KEY = 'reconciliation_claimed_at'.freeze
  DISPATCH_RESERVED_AT_KEY = 'reconciliation_dispatch_reserved_at'.freeze

  def initialize(command:, now: -> { Time.current })
    @command = command
    @now = now
  end

  def claim_attempt!
    command.with_lock do
      command.reload
      next unless claimable?

      token = SecureRandom.uuid
      command.update!(
        status: command.status_for_transition('processing'),
        execution_state: claimed_state(token)
      )
      token
    end
  end

  def reserve_unknown_dispatch!
    command.with_lock do
      command.reload
      next false unless command.provider_status_unknown?
      next false unless command.reconciliation_next_at.blank? || command.reconciliation_next_at <= current_time

      command.update!(execution_state: reserved_dispatch_state)
      true
    end
  end

  def retry_unresolved!(error_code, claim_token:, status: nil)
    command.with_lock do
      command.reload
      next unless claim_owned?(claim_token)

      if command.reconciliation_attempts >= Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS
        mark_provider_status_unknown_locked!(reason: error_code, status: status)
        next
      end

      command.update!(
        status: command.status_for_transition('reconciliation_required'),
        execution_state: released_state.merge('reconciliation_next_at' => (current_time + backoff).iso8601),
        last_error_code: error_code,
        last_error_status: status
      )
    end
  end

  def fail!(error_code, status: nil, claim_token: nil)
    command.with_lock do
      command.reload
      next unless claim_token.present? ? claim_owned?(claim_token) : command.reconcilable?

      fail_locked!(error_code, status: status)
    end
  end

  def defer_unknown!(reason, status: nil, claim_token: nil)
    command.with_lock do
      command.reload
      next unless claim_token.present? ? claim_owned?(claim_token) : command.reconcilable?

      mark_provider_status_unknown_locked!(reason: reason, status: status)
    end
  end

  def mark_unknown_if_exhausted!
    command.with_lock do
      command.reload
      next unless command.reconciliation_required?
      next if command.reconciliation_attempts < Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS

      mark_provider_status_unknown_locked!(reason: 'reconciliation_exhausted')
    end
  end

  private

  attr_reader :command, :now

  def claimable?
    return false unless command.reconcilable?

    return false if command.reconciliation_required? &&
                    command.reconciliation_attempts >= Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS

    dispatch_reserved? || command.reconciliation_next_at.blank? || command.reconciliation_next_at <= current_time
  end

  def dispatch_reserved?
    command.execution_state.to_h[DISPATCH_RESERVED_AT_KEY].present?
  end

  def claim_owned?(token)
    command.processing? && command.execution_state.to_h[CLAIM_TOKEN_KEY] == token
  end

  def claimed_state(token)
    claimed_at = current_time.iso8601
    command.execution_state.to_h.except('reconciliation_next_at', DISPATCH_RESERVED_AT_KEY).merge(
      CLAIM_TOKEN_KEY => token,
      CLAIMED_AT_KEY => claimed_at,
      'execution_started_at' => claimed_at,
      'reconciliation_attempts' => command.reconciliation_attempts + 1,
      'reconciliation_last_attempt_at' => claimed_at
    )
  end

  def reserved_dispatch_state
    command.execution_state.to_h.merge(
      DISPATCH_RESERVED_AT_KEY => current_time.iso8601,
      'reconciliation_next_at' => (
        current_time + Integrations::Medelement::ProviderCommand::PROVIDER_STATUS_UNKNOWN_BACKOFF
      ).iso8601
    )
  end

  def released_state
    command.execution_state.to_h.except(CLAIM_TOKEN_KEY, CLAIMED_AT_KEY, DISPATCH_RESERVED_AT_KEY, 'reconciliation_next_at')
  end

  def backoff
    Integrations::Medelement::ProviderCommand::RECONCILIATION_BACKOFFS.fetch(
      command.reconciliation_attempts - 1,
      Integrations::Medelement::ProviderCommand::RECONCILIATION_BACKOFFS.last
    )
  end

  def current_time
    now.call
  end

  def fail_locked!(error_code, status: nil)
    project_appointment_status!(Integrations::Medelement::AppointmentProviderStatus::FAILED)
    command.update!(
      status: 'failed',
      executed_at: current_time,
      last_error_code: error_code,
      last_error_status: status,
      execution_state: released_state
    )
  end

  def mark_provider_status_unknown_locked!(reason:, status: nil)
    project_appointment_status!(Integrations::Medelement::AppointmentProviderStatus::UNKNOWN)
    command.update!(
      status: command.status_for_transition('provider_status_unknown'),
      last_error_code: 'provider_status_unknown',
      last_error_status: status,
      execution_state: released_state.merge(
        'provider_status_unknown_reason' => reason,
        'reconciliation_next_at' => (
          current_time + Integrations::Medelement::ProviderCommand::PROVIDER_STATUS_UNKNOWN_BACKOFF
        ).iso8601
      )
    )
  end

  def project_appointment_status!(status)
    Integrations::Medelement::AppointmentProviderStatus.persist!(command.appointment, status)
  end
end
