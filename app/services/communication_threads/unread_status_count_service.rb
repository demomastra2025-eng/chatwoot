# Unread threads per status tab. A person is counted once, under the status of the thread itself (the most urgent status of
# the channels, see Conversations::CommunicationThreadResolver), the same status the tabs of CommunicationThreadFinder match,
# so the numbers add up to the lists: a person who is open in one channel and resolved in another is not counted as resolved.
# thread_scope is the (permission filtered) set of unread threads; the statuses of the single channels play no part.
class CommunicationThreads::UnreadStatusCountService
  STATUS_KEYS = %w[open pending snoozed resolved].freeze

  def initialize(account:, thread_scope:)
    @account = account
    @thread_scope = thread_scope
  end

  def perform
    counts_by_status = CommunicationThread.where(account_id: account.id, id: unread_thread_ids).group(:status).count

    STATUS_KEYS.index_with { |status| counts_by_status.fetch(status, 0) }
  end

  private

  attr_reader :account, :thread_scope

  def unread_thread_ids
    thread_scope.except(:order).reselect('communication_threads.id')
  end
end
