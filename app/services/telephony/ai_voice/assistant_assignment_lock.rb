require 'digest'

class Telephony::AiVoice::AssistantAssignmentLock
  class << self
    def acquire!(inbox_id)
      raise ArgumentError, 'inbox_id is required' if inbox_id.blank?
      raise 'assistant assignment lock requires an open transaction' unless connection.transaction_open?

      lock_id = Digest::SHA256.digest("ai-voice-assistant-assignment:#{inbox_id}").unpack1('q>')
      connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
    end

    private

    def connection
      ActiveRecord::Base.connection
    end
  end
end
