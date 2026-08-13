require 'digest'

class Contacts::PhoneIdentityLock
  PREFIX = 'contact-phone-identity'.freeze

  def self.acquire!(account_id:)
    raise ArgumentError, 'account_id is required' if account_id.blank?
    raise 'phone identity lock requires an open transaction' unless ActiveRecord::Base.connection.transaction_open?

    identity = "#{PREFIX}:#{account_id}"
    lock_id = Digest::SHA256.digest(identity).unpack1('q>')
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
  end
end
