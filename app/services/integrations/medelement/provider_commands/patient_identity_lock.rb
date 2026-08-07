class Integrations::Medelement::ProviderCommands::PatientIdentityLock
  LocalLock = Data.define(:mutex, :users)

  class << self
    def synchronize_local(key, &)
      entry = local_locks_guard.synchronize do
        current = local_locks[key] || LocalLock.new(mutex: Mutex.new, users: 0)
        local_locks[key] = current.with(users: current.users + 1)
      end
      entry.mutex.synchronize(&)
    ensure
      release_local(key) if entry
    end

    private

    def release_local(key)
      local_locks_guard.synchronize do
        current = local_locks.fetch(key)
        if current.users == 1
          local_locks.delete(key)
        else
          local_locks[key] = current.with(users: current.users - 1)
        end
      end
    end

    def local_locks
      @local_locks ||= {}
    end

    def local_locks_guard
      @local_locks_guard ||= Mutex.new
    end
  end

  def initialize(account_id:, iin:)
    @account_id = account_id
    @iin = Scheduling::IinValidator.normalize(iin)
    raise ArgumentError, 'valid IIN is required for patient identity lock' unless Scheduling::IinValidator.valid?(@iin)
  end

  def synchronize
    self.class.synchronize_local(lock_key) do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        acquired = false
        connection.execute("SELECT pg_advisory_lock(#{connection.quote(lock_key)})")
        acquired = true
        yield
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{connection.quote(lock_key)})") if acquired
      end
    end
  end

  private

  attr_reader :account_id, :iin

  def lock_key
    @lock_key ||= Digest::SHA256.digest("medelement-patient-identity:#{account_id}:#{iin}").unpack1('q>')
  end
end
