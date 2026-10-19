# What a user may find through a search box: the conversations he may open (Conversations::PermissionFilterService, which
# knows the custom roles), the inboxes of his messages, and whether his role is narrower than his inboxes.
class Search::AccessScope
  def initialize(account:, user:)
    @account = account
    @user = user
  end

  # The conversations the user may open.
  def conversations
    @conversations ||= Conversations::PermissionFilterService.new(@account.conversations, @user, @account).perform
  end

  # nil means "every inbox of the account" (administrator or default manager with full channel access).
  def inbox_ids
    return if account_user&.administrator? || unrestricted_inbox_access?

    @user.inboxes.where(account_id: @account.id).pluck(:id)
  end

  # A custom role (an agent with permissions of its own) opens fewer conversations than the inboxes it belongs to, so
  # the inbox is not enough to say that a message may be shown.
  def restricted?
    account_user.present? && account_user.agent? && account_user.custom_role_id.present?
  end

  private

  def unrestricted_inbox_access?
    return @unrestricted_inbox_access if defined?(@unrestricted_inbox_access)

    @unrestricted_inbox_access = !@account.inboxes.where.not(
      id: InboxMember.where(user_id: @user.id).select(:inbox_id)
    ).exists?
  end

  def account_user
    return @account_user if defined?(@account_user)

    @account_user = @account.account_users.find_by(user_id: @user.id)
  end
end
