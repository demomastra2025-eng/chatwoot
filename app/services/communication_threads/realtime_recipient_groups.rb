class CommunicationThreads::RealtimeRecipientGroups
  def initialize(account:, links:, source_conversation:)
    @account = account
    @links = links
    @source_conversation = source_conversation
  end

  def perform
    visible_links_by_user.each_with_object({}) do |(user, visible_links), groups|
      visible_links = visible_source_links(user, visible_links)
      next if visible_links.blank?

      group = groups[visible_links.map(&:id)] ||= { links: nil, users: [] }
      group[:links] ||= visible_links
      group[:users] << user
    end
  end

  private

  attr_reader :account, :links, :source_conversation

  def visible_source_links(user, visible_links)
    visible_links = permission_filtered_links(user, visible_links) if custom_role_user?(user)
    return unless visible_links.any? { |link| link.conversation_id == source_conversation.id }

    visible_links
  end

  def visible_links_by_user
    result = Hash.new { |hash, user| hash[user] = [] }
    links.each do |link|
      link.inbox.members.each { |user| result[user] << link }
    end
    account.administrators.each { |user| result[user] = links }

    result
  end

  def custom_role_user?(user)
    account_user = account_users_by_user_id[user.id]
    account_user&.agent? && account_user.custom_role_id.present?
  end

  def permission_filtered_links(user, visible_links)
    accessible_ids = Conversations::PermissionFilterService.new(
      account.conversations.where(id: visible_links.map(&:conversation_id)),
      user,
      account
    ).perform.pluck(:id)
    visible_links.select { |link| accessible_ids.include?(link.conversation_id) }
  end

  def account_users_by_user_id
    @account_users_by_user_id ||= account.account_users.index_by(&:user_id)
  end
end
