module Current
  thread_mattr_accessor :user
  thread_mattr_accessor :account
  thread_mattr_accessor :account_user
  thread_mattr_accessor :executed_by
  thread_mattr_accessor :contact
  thread_mattr_accessor :suppress_runtime_events

  def self.with_runtime_events_suppressed
    previous_value = Current.suppress_runtime_events
    Current.suppress_runtime_events = true
    yield
  ensure
    Current.suppress_runtime_events = previous_value
  end

  def self.reset
    Current.user = nil
    Current.account = nil
    Current.account_user = nil
    Current.executed_by = nil
    Current.contact = nil
    Current.suppress_runtime_events = nil
  end
end
