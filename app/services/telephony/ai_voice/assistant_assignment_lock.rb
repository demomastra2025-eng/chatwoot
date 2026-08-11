require 'digest'

class Telephony::AiVoice::AssistantAssignmentLock
  class << self
    def acquire!(inbox_id)
      lock_id = lock_id_for(inbox_id)
      raise 'assistant assignment lock requires an open transaction' unless connection.transaction_open?

      connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
    end

    def with_lock!(inbox_id)
      lock_id = lock_id_for(inbox_id)
      connection_pool.with_connection do |leased_connection|
        acquired = false
        leased_connection.execute("SELECT pg_advisory_lock(#{lock_id})")
        acquired = true
        yield
      ensure
        leased_connection.execute("SELECT pg_advisory_unlock(#{lock_id})") if acquired
      end
    end

    private

    def lock_id_for(inbox_id)
      raise ArgumentError, 'inbox_id is required' if inbox_id.blank?

      Digest::SHA256.digest("ai-voice-assistant-assignment:#{inbox_id}").unpack1('q>')
    end

    def connection
      ActiveRecord::Base.connection
    end

    def connection_pool
      ActiveRecord::Base.connection_pool
    end
  end
end
