require 'digest'

# One physical inbound call reaches the server as several legs: every operator
# browser registered on the channel reports its own INVITE within a few
# seconds, and each leg creates or updates the same contact, conversation and
# voice message. The legs must take turns.
#
# The lock is keyed like the one Voice::InboundCallBuilder takes (account and
# caller number), so taking it earlier than the builder does is safe. The order
# everywhere is: this advisory lock first, then the call session row, then the
# conversation and its messages. It is a transaction level lock: it is released
# when the surrounding transaction ends.
class Telephony::CallIntakeLock
  class << self
    def lock_id(account_id, phone_number)
      identity = ['voice-contact', account_id, normalize(phone_number)].join(':')
      Digest::SHA256.digest(identity).unpack1('q>')
    end

    # Blocks until the legs ahead of us are done. Needs an open transaction.
    def acquire!(account_id:, phone_number:)
      return if account_id.blank? || phone_number.blank?

      ActiveRecord::Base.connection.exec_query(
        'SELECT pg_advisory_xact_lock($1)', 'Telephony::CallIntakeLock', [lock_id(account_id, phone_number)]
      )
    end

    def with_lock(account_id:, phone_number:, &)
      ActiveRecord::Base.transaction do
        acquire!(account_id: account_id, phone_number: phone_number)
        yield
      end
    end

    def normalize(phone_number)
      Contacts::PhoneNumberNormalizer.normalize(phone_number) ||
        Contacts::PhoneNumberNormalizer.normalize(phone_number, default_country: 'KZ') ||
        phone_number.to_s
    end
  end
end
