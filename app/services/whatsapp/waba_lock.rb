require 'digest'

class Whatsapp::WabaLock
  class LockAcquisitionError < StandardError; end

  THREAD_LOCKS_KEY = :whatsapp_waba_advisory_locks

  class << self
    def with_locks(waba_ids, &)
      ids = Array(waba_ids).compact_blank.map(&:to_s).uniq.sort
      return yield if ids.empty?

      first, *remaining = ids
      new(first).with_lock { with_locks(remaining, &) }
    end

    def process_lock_guard
      @process_lock_guard ||= Mutex.new
    end

    def process_lock_owners
      @process_lock_owners ||= {}
    end
  end

  def initialize(waba_id)
    @waba_id = waba_id.to_s
  end

  def with_lock(&)
    raise ArgumentError, 'WABA ID is required' if @waba_id.blank?

    held_locks = Thread.current[THREAD_LOCKS_KEY] ||= {}
    return yield if held_locks[lock_id]

    process_lock_acquired = acquire_process_lock!

    with_database_lock(held_locks, &)
  ensure
    release_process_lock if process_lock_acquired
    Thread.current[THREAD_LOCKS_KEY] = nil if held_locks&.empty?
  end

  private

  def acquire_lock(connection)
    value = connection.select_value("SELECT pg_try_advisory_lock(#{quoted_lock_id(connection)})")
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def acquire_process_lock
    self.class.process_lock_guard.synchronize do
      next false if self.class.process_lock_owners.key?(lock_id)

      self.class.process_lock_owners[lock_id] = Thread.current.object_id
      true
    end
  end

  def acquire_process_lock!
    return true if acquire_process_lock

    raise LockAcquisitionError, "Failed to acquire WABA routing lock for #{@waba_id}"
  end

  def release_process_lock
    self.class.process_lock_guard.synchronize do
      owners = self.class.process_lock_owners
      owners.delete(lock_id) if owners[lock_id] == Thread.current.object_id
    end
  end

  def with_database_lock(held_locks)
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      acquired = acquire_lock(connection)
      raise LockAcquisitionError, "Failed to acquire WABA routing lock for #{@waba_id}" unless acquired

      held_locks[lock_id] = true
      yield
    ensure
      held_locks.delete(lock_id)
      release_lock(connection) if acquired
    end
  end

  def release_lock(connection)
    connection.select_value("SELECT pg_advisory_unlock(#{quoted_lock_id(connection)})")
  end

  def quoted_lock_id(connection)
    connection.quote(lock_id)
  end

  def lock_id
    @lock_id ||= Digest::SHA256.hexdigest("whatsapp-waba-routing:#{@waba_id}").first(15).to_i(16)
  end
end
