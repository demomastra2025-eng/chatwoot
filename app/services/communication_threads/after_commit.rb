# Rails 7.1 transaction records carry callbacks through nested savepoints.
# Register a fresh record per callback so rolled-back membership changes never publish realtime events.
class CommunicationThreads::AfterCommit
  def self.run(&)
    connection = ApplicationRecord.connection
    return yield unless connection.transaction_open?

    connection.add_transaction_record(new(&))
  end

  def initialize(&block)
    @callback = block
  end

  def trigger_transactional_callbacks?
    true
  end

  def before_committed!; end

  def committed!(should_run_callbacks: true)
    @callback.call if should_run_callbacks
  end

  def rolledback!(**); end
end
