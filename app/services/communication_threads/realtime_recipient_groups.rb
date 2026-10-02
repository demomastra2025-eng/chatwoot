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
    account_user = account_users_by_user_id[user.id]
    return if account_user.blank?

    user_context = { user: user, account: account, account_user: account_user }
    visible_links = visible_links.select do |link|
      conversation = link.conversation
      conversation&.account_id == account.id && ConversationPolicy.new(user_context, conversation).show?
    end
    return unless visible_links.any? { |link| link.conversation_id == source_conversation.id }

    visible_links
  end

  def visible_links_by_user
    result = Hash.new { |hash, user| hash[user] = [] }
    preload_team_members

    links.each { |link| add_link_members_to_visible_users(result, link) }
    account.administrators.each { |user| result[user] = links }

    result
  end

  def add_link_members_to_visible_users(result, link)
    members = link.inbox.members.to_a
    team = link.conversation&.team
    members.concat(team.members.to_a) if team&.account_id == account.id
    members.uniq.each { |user| result[user] << link }
  end

  def preload_team_members
    conversations = links.filter_map(&:conversation)
                         .select { |conversation| conversation.account_id == account.id }
                         .uniq
    return if conversations.empty?

    ActiveRecord::Associations::Preloader.new(records: conversations, associations: { team: :members }).call
  end

  def account_users_by_user_id
    @account_users_by_user_id ||= account.account_users.index_by(&:user_id)
  end
end
