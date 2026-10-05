class Conversations::PermissionFilterService
  attr_reader :conversations, :user, :account

  def initialize(conversations, user, account)
    @conversations = conversations
    @user = user
    @account = account
  end

  def perform
    return conversations_for_captain_assistant if captain_assistant_actor?
    return conversations if user_role == 'administrator'

    accessible_conversations
  end

  private

  def conversations_for_captain_assistant
    scoped_inboxes = user.inboxes.where(account_id: account.id)
    return conversations.none if scoped_inboxes.blank?

    conversations.where(inbox: scoped_inboxes)
  end

  def captain_assistant_actor?
    defined?(Captain::Assistant) && user.is_a?(Captain::Assistant)
  end

  def accessible_conversations
    conversations.where(inbox: user.inboxes.where(account_id: account.id))
  end

  # The role lookup runs several times per request (counts, lists, unread scopes), so it is
  # reused from the request's account user when that is the same membership, and kept per instance.
  def account_user
    return @account_user if defined?(@account_user)

    @account_user = current_account_user || AccountUser.find_by(account_id: account.id, user_id: user.id)
  end

  def current_account_user
    return unless user.is_a?(User)

    current = Current.account_user
    current if current.present? && current.account_id == account.id && current.user_id == user.id
  end

  def user_role
    account_user&.role
  end
end

Conversations::PermissionFilterService.prepend_mod_with('Conversations::PermissionFilterService')
