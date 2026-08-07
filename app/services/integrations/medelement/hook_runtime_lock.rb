require 'digest'

class Integrations::Medelement::HookRuntimeLock
  class << self
    def with_hook(account_id:, hook_id:)
      Integrations::Hook.transaction(requires_new: true) do
        acquire!(account_id: account_id, hook_id: hook_id)
        hook = Integrations::Hook.find_by!(id: hook_id, account_id: account_id)
        yield hook
      end
    end

    def acquire!(account_id:, hook_id:)
      raise ArgumentError, 'account_id and hook_id are required' if account_id.blank? || hook_id.blank?
      raise 'Medelement hook runtime lock requires an open transaction' unless connection.transaction_open?

      connection.execute("SELECT pg_advisory_xact_lock(#{connection.quote(lock_id(account_id, hook_id))})")
    end

    private

    def lock_id(account_id, hook_id)
      Digest::SHA256.digest("medelement-hook-runtime:#{account_id}:#{hook_id}").unpack1('q>')
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
