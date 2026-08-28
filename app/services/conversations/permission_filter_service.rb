class Conversations::PermissionFilterService
  attr_reader :conversations, :user, :account

  def initialize(conversations, user, account)
    @conversations = conversations
    @user = user
    @account = account
  end

  def perform
    return conversations_for_captain_assistant if captain_assistant_actor?
    return accessible_conversations if account_member?

    conversations.none
  end

  def perform_operational
    return conversations_for_captain_assistant if captain_assistant_actor?
    return operational_conversations if account_member?

    conversations.none
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
    conversations.where(inbox_id: accessible_inbox_ids)
  end

  def accessible_inbox_ids
    account.inboxes.select(:id)
  end

  def operational_conversations
    conversations.where(inbox_id: operational_inbox_ids)
  end

  def operational_inbox_ids
    account_inboxes = account.inboxes
    return account_inboxes.select(:id) if user_role == 'administrator'

    messaging_inboxes = account_inboxes.where.not(channel_type: 'Channel::Voice')
    assigned_voice_inboxes = user.inboxes.where(account_id: account.id, channel_type: 'Channel::Voice')

    messaging_inboxes.or(account_inboxes.where(id: assigned_voice_inboxes.select(:id))).select(:id)
  end

  def account_user
    AccountUser.find_by(account_id: account.id, user_id: user.id)
  end

  def user_role
    account_user&.role
  end

  def account_member?
    user_role.in?(%w[administrator agent])
  end
end

Conversations::PermissionFilterService.prepend_mod_with('Conversations::PermissionFilterService')
