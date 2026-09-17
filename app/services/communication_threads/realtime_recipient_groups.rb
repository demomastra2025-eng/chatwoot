class CommunicationThreads::RealtimeRecipientGroups
  def initialize(account:, communication_thread:, links:, source_conversation:, recipient_user_ids: [])
    @account = account
    @communication_thread = communication_thread
    @links = links
    @source_conversation = source_conversation
    @recipient_user_ids = Array(recipient_user_ids).map(&:to_i)
  end

  def perform
    participant_user_ids = communication_thread.communication_thread_participants.pluck(:user_id)
    access_contexts = CommunicationThreads::RealtimeAccessSnapshotBuilder.new(account, participant_user_ids).perform

    access_contexts.each_value.each_with_object({}) do |access_context, groups|
      account_user = access_context[:account_user]
      user = account_user.user
      policy = communication_thread_policy(user, access_context)
      visible_links = recipient_visible_links(user, participant_user_ids, policy)
      next if visible_links.blank?
      next unless visible_links.any? { |link| link.conversation_id == source_conversation.id }

      group = groups[visible_links.map(&:id).sort] ||= { links: nil, recipients: [] }
      group[:links] ||= visible_links
      group[:recipients] << {
        user: user,
        policy: policy,
        participant: participant_user_ids.include?(user.id)
      }
    end
  end

  private

  attr_reader :account, :communication_thread, :links, :source_conversation, :recipient_user_ids

  def recipient_visible_links(user, participant_user_ids, policy)
    return links if recipient_user_ids.include?(user.id) || participant_user_ids.include?(user.id)

    policy.show? ? links : []
  end

  def communication_thread_policy(user, access_context)
    CommunicationThreadPolicy.new(
      {
        user: user,
        account: account,
        account_user: access_context[:account_user],
        thread_access_snapshot: access_context[:thread_access_snapshot]
      },
      communication_thread
    )
  end
end
