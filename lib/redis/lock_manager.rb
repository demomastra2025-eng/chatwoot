# Redis::LockManager provides a simple mechanism to handle distributed locks using Redis.
# This class ensures that only one instance of a given operation runs at a given time across all processes/nodes.
# It uses the $alfred Redis namespace for all its operations.
#
# Example Usage:
#
# lock_manager = Redis::LockManager.new
#
# if lock_manager.lock("some_key")
#   # Critical code that should not be run concurrently
#   lock_manager.unlock("some_key")
# end
#
class Redis::LockManager
  # Default lock timeout set to 1 second. This means that if the lock isn't released
  # within 1 second, it will automatically expire.
  # This helps to avoid deadlocks in case the process holding the lock crashes or fails to release it.
  LOCK_TIMEOUT = 1.second

  def initialize
    @lock_tokens = {}
  end

  # Attempts to acquire a lock for the given key.
  #
  # If the lock is successfully acquired, the method returns true. If the key is
  # already locked or if any other error occurs, it returns false.
  #
  # === Parameters
  # * +key+ - The key for which the lock is to be acquired.
  # * +timeout+ - Duration in seconds for which the lock is valid. Defaults to +LOCK_TIMEOUT+.
  #
  # === Returns
  # * +true+ if the lock was successfully acquired.
  # * +false+ if the lock was not acquired.
  def lock(key, timeout = LOCK_TIMEOUT)
    value = SecureRandom.uuid
    # nx: true means set the key only if it does not exist
    acquired = Redis::Alfred.set(key, value, nx: true, ex: timeout).present?
    @lock_tokens[key] = value if acquired
    acquired
  end

  # Releases a lock for the given key.
  #
  # === Parameters
  # * +key+ - The key for which the lock is to be released.
  #
  # === Returns
  # * +true+ indicating the lock release operation was initiated.
  #
  # Note: If the key wasn't locked, this operation will have no effect.
  def unlock(key)
    value = @lock_tokens.delete(key)
    return false unless value

    Redis::Alfred.delete_if_value(key, value).positive?
  end

  def renew(key, timeout)
    value = @lock_tokens[key]
    return false unless value

    result = Redis::Alfred.expire_if_value(key, value, timeout.to_i)
    result == true || result.to_i.positive?
  end

  # Checks if the given key is currently locked.
  #
  # === Parameters
  # * +key+ - The key to check.
  #
  # === Returns
  # * +true+ if the key is locked.
  # * +false+ otherwise.
  def locked?(key)
    Redis::Alfred.exists?(key)
  end
end
