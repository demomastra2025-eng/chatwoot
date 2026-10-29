module Current
  thread_mattr_accessor :user
  thread_mattr_accessor :account
  thread_mattr_accessor :account_user
  thread_mattr_accessor :request_id
  thread_mattr_accessor :executed_by
  thread_mattr_accessor :contact
  thread_mattr_accessor :suppress_runtime_events
  thread_mattr_accessor :playground_run_policy
  thread_mattr_accessor :medelement_reconciliation

  def self.with_runtime_events_suppressed
    previous_value = Current.suppress_runtime_events
    Current.suppress_runtime_events = true
    yield
  ensure
    Current.suppress_runtime_events = previous_value
  end

  def self.without_account_user
    previous_value = Current.account_user
    Current.account_user = nil
    yield
  ensure
    Current.account_user = previous_value
  end

  # A past MedElement visit whose status is being corrected from the provider (StaleStatusReconciler). While it is set,
  # Dispatcher holds back appointment events and Reminders::SyncEnrollmentService only closes touches, never refreshes
  # them: no automation rule, CRM re-evaluation or reminder reacts. It only holds inside the block, so a normal sync is
  # never affected.
  def self.with_medelement_reconciliation
    previous_value = Current.medelement_reconciliation
    Current.medelement_reconciliation = true
    yield
  ensure
    Current.medelement_reconciliation = previous_value
  end

  def self.reset
    Current.user = nil
    Current.account = nil
    Current.account_user = nil
    Current.request_id = nil
    Current.executed_by = nil
    Current.contact = nil
    Current.suppress_runtime_events = nil
    Current.playground_run_policy = nil
    Current.medelement_reconciliation = nil
  end

  # A rule can finish while the same event is still executing other rules and listeners.
  # Clear its actor context without losing the original run's delivery restrictions.
  def self.reset_preserving_playground_policy!
    policy = Current.playground_run_policy
    reset
    Current.playground_run_policy = policy
  end
end
