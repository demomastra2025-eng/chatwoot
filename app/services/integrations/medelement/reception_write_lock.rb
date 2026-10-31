require 'digest'

# Shared by full snapshots and delta imports for one reception write at a time.
# It is released with the transaction, including rollback or a lost DB connection.
class Integrations::Medelement::ReceptionWriteLock
  def self.with_account(account_id:)
    raise ArgumentError, 'account_id is required' if account_id.blank?

    ApplicationRecord.transaction do
      connection = ActiveRecord::Base.connection
      key = Digest::SHA256.digest("medelement-reception-write:#{account_id}").unpack1('q>')
      connection.execute("SELECT pg_advisory_xact_lock(#{connection.quote(key)})")
      yield
    end
  end
end
