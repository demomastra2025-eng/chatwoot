# Search box of the conversation list in communication-thread mode. Same contract as Conversations::ListSearchService:
# the query and the page are the only inputs, every list filter (status, assignee, inbox, team, label, CRM stage,
# unread) is ignored, and the permission scope decides what the user may see. A thread is found through its contact,
# the number of the thread or of one of its conversations, or the text of a message in one of its conversations; only
# threads that have at least one conversation the user can open are returned, and what makes a thread appear is only
# ever a conversation of that kind (Search::ConversationLookup is given the permitted conversations), so the name or the
# phone number of a contact whose conversations the user cannot open does not leak through the thread.
#
# Result: { communication_threads: <page>, count: { search: true, total_count:, capped:, partial:, ... } }
class CommunicationThreads::ListSearchService
  PER_PAGE = ENV.fetch('CONVERSATION_RESULTS_PER_PAGE', '25').to_i
  # Same associations the thread list loads (see CommunicationThreadFinder).
  LIST_INCLUDES = [
    {
      contact: [
        { contact_channel_profiles: { avatar_attachment: :blob } },
        { avatar_attachment: :blob },
        { owner: [:account_users, { avatar_attachment: :blob }] }
      ]
    },
    { assignee: [:account_users, { avatar_attachment: :blob }] },
    :team
  ].freeze

  def initialize(user:, account:, params:)
    @user = user
    @account = account
    @params = params
  end

  def perform
    page = CommunicationThread.where(account_id: @account.id, id: thread_ids).includes(*LIST_INCLUDES)
                              .order(CommunicationThread.arel_table[:last_activity_at].desc.nulls_last, id: :desc)
                              .page(current_page).per(PER_PAGE)

    { communication_threads: page, count: count_for(page) }
  end

  private

  def thread_ids
    linked = CommunicationThreadConversation.where(account_id: @account.id, conversation_id: lookup.conversation_ids)
    (linked.distinct.pluck(:communication_thread_id) | thread_id_by_display_id).first(Search::ConversationLookup::CONVERSATION_LIMIT)
  end

  def thread_id_by_display_id
    return [] if lookup.display_id.blank?

    thread_id = CommunicationThread.where(account_id: @account.id, display_id: lookup.display_id).pick(:id)
    return [] if thread_id.blank?

    accessible = CommunicationThreadConversation.exists?(
      account_id: @account.id, communication_thread_id: thread_id, conversation_id: access.conversations.select(:id)
    )
    accessible ? [thread_id] : []
  end

  def access
    @access ||= Search::AccessScope.new(account: @account, user: @user)
  end

  def lookup
    @lookup ||= Search::ConversationLookup.new(
      account: @account, raw_query: @params[:q], access: access
    )
  end

  def current_page
    [@params[:page].to_i, 1].max
  end

  def count_for(page)
    { search: true, total_count: page.total_count, capped: lookup.capped?, partial: lookup.partial?, current_page: page.current_page,
      per_page: PER_PAGE }
  end
end
