# frozen_string_literal: true

require 'digest'

# The lock of one person (an advisory lock held until the end of the current transaction). Everything that creates, links or
# removes the conversations of a person takes it first: the thread resolver, the first message or call of a dialog, the
# repair of the unread counts and the cleanup after a deletion. One key for all of them is what makes two staff members who
# write to a person who has no dialog yet end up in one dialog.
module CommunicationThreads::PersonLock
  module_function

  def lock!(account_id:, contact_id:)
    identity = "communication-thread:#{account_id}:#{contact_id}"
    lock_id = Digest::SHA256.digest(identity).unpack1('q>')

    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
  end
end
