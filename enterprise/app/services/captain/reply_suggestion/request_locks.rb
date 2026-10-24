# frozen_string_literal: true

# What a reply suggestion request holds while it is queued or running: the lock of the user and the conversation (one active run for
# both), and a slot of the account (a cap on its active runs, so that suggestions cannot starve the live replies of the workers).
module Captain::ReplySuggestion::RequestLocks
  PREFIX = Captain::ReplySuggestion::RequestStore::PREFIX

  class << self
    # One active run per user and conversation. Returns nil when the lock was taken, or the id of the run that holds it.
    def claim_active(account_id, user_id, conversation_id, id)
      lock = active_key(account_id, user_id, conversation_id)
      return if Redis::Alfred.set(lock, id, nx: true, ex: Captain::ReplySuggestion.active_lock_ttl_seconds)

      Redis::Alfred.get(lock)
    end

    def release_active(account_id, user_id, conversation_id, id)
      Redis::Alfred.delete_if_value(active_key(account_id, user_id, conversation_id), id)
    end

    # The cap of runs of one account that are queued or running. A lost job frees its slot when the score (expiry) passes.
    def claim_account_slot(account_id, id)
      slots = account_active_key(account_id)
      Redis::Alfred.zremrangebyscore(slots, '-inf', Time.current.to_i)
      return false if Redis::Alfred.zcard(slots) >= Captain::ReplySuggestion.max_active_per_account

      Redis::Alfred.zadd(slots, Time.current.to_i + Captain::ReplySuggestion::ACCOUNT_SLOT_TTL_SECONDS, id)
      Redis::Alfred.expire(slots, Captain::ReplySuggestion::ACCOUNT_SLOT_TTL_SECONDS)
      true
    end

    def release_account_slot(account_id, id)
      Redis::Alfred.zrem(account_active_key(account_id), id)
    end

    # Frees what a request held (the active lock and the account slot). Safe to call more than once.
    def release!(record)
      return if record.blank?

      release_active(record['account_id'], record['user_id'], record['conversation_id'], record['id'])
      release_account_slot(record['account_id'], record['id'])
    end

    def active_key(account_id, user_id, conversation_id) = "#{PREFIX}:active:#{account_id}:#{user_id}:#{conversation_id}"
    def account_active_key(account_id) = "#{PREFIX}:account_active:#{account_id}"
  end
end
