# Search box of the conversation list (classic mode). It always looks through all statuses and all assignees, whatever
# the list is currently filtered by: the only things it reads from the request are the query (`q`) and the page. Status,
# assignee, inbox, team, label, CRM stage, appointment and unread filters are never applied, so the person who sits in
# "Open / Mine" still finds a resolved conversation of a colleague. What the user may see is still decided by
# Conversations::PermissionFilterService (see Search::ConversationLookup).
#
# Result: { conversations: <page>, meta: { search: true, total_count:, capped:, partial:, ... } }
class Conversations::ListSearchService
  PER_PAGE = ENV.fetch('CONVERSATION_RESULTS_PER_PAGE', '25').to_i
  LIST_INCLUDES = [
    :taggings, :inbox, { assignee: { avatar_attachment: [:blob] } }, { contact: { avatar_attachment: [:blob] } },
    :team, :conversation_participants, { contact_inbox: :channel_profile }, :assignee_agent_bot
  ].freeze

  def initialize(user:, account:, params:)
    @user = user
    @account = account
    @params = params
  end

  def perform
    ids = lookup.conversation_ids
    page = access.conversations.where(id: ids).includes(*LIST_INCLUDES)
                 .sort_on_last_activity_at(:desc).order(id: :desc).page(current_page).per(PER_PAGE)

    { conversations: page, meta: meta_for(page) }
  end

  private

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

  def meta_for(page)
    { search: true, total_count: page.total_count, capped: lookup.capped?, partial: lookup.partial?, current_page: page.current_page,
      per_page: PER_PAGE }
  end
end
