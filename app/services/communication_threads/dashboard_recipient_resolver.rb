# frozen_string_literal: true

class CommunicationThreads::DashboardRecipientResolver
  FEATURE_NAME = 'communication_threads'

  def initialize(account:, conversation:)
    @account = account
    @conversation = conversation
  end

  def perform
    return communication_thread_agents if communication_thread_enabled?

    legacy_agents
  end

  private

  attr_reader :account, :conversation

  def communication_thread_enabled?
    account.feature_enabled?(FEATURE_NAME) && conversation.communication_thread.present?
  end

  def communication_thread_agents
    thread = conversation.communication_thread
    participant_user_ids = thread.communication_thread_participants.pluck(:user_id)
    CommunicationThreads::RealtimeAccessSnapshotBuilder
      .new(account, participant_user_ids)
      .permitted_agents(record: conversation)
  end

  def legacy_agents
    participant_user_ids = conversation.conversation_participants.pluck(:user_id)
    account.account_users
           .where(role: :agent)
           .includes(:user, :custom_role)
           .filter_map do |account_user|
      user = account_user.user
      user if ConversationPolicy.new(policy_context(account_user, participant_user_ids), conversation).show?
    end
  end

  def policy_context(account_user, participant_user_ids)
    {
      user: account_user.user,
      account: account,
      account_user: account_user,
      participant_user_ids: participant_user_ids
    }
  end
end
