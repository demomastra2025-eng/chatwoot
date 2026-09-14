# frozen_string_literal: true

class CommunicationThreads::RealtimeAccessSnapshotBuilder
  CAPABILITIES = %w[view assign].freeze

  def initialize(account, participant_user_ids)
    @account = account
    @participant_user_ids = participant_user_ids
  end

  def perform
    mode = AccessControl::ModeResolver.mode_for_account(account.id)
    account.account_users
           .includes(:custom_role, { access_role: :grants }, user: :team_members)
           .to_h { |account_user| [account_user.user_id, access_context(account_user, mode)] }
  end

  def permitted_agents(record:)
    perform.values.filter_map do |context|
      account_user = context[:account_user]
      next unless account_user.agent?

      user = account_user.user
      user if ConversationPolicy.new(policy_context(context), record).show?
    end
  end

  private

  attr_reader :account, :participant_user_ids

  def policy_context(context)
    {
      user: context[:account_user].user,
      account: account,
      account_user: context[:account_user],
      participant_user_ids: participant_user_ids,
      thread_access_snapshot: context[:thread_access_snapshot]
    }
  end

  def access_context(account_user, mode)
    {
      account_user: account_user,
      thread_access_snapshot: {
        participant: participant_user_ids.include?(account_user.user_id),
        team_ids: account_user.user.team_members.map(&:team_id),
        mode_resolutions: CAPABILITIES.index_with { |capability| mode_resolution(account_user, capability, mode) }
      }
    }
  end

  def mode_resolution(account_user, capability, mode)
    AccessControl::ModeResolver::Result.new(
      account_id: account_user.account_id,
      mode: mode,
      authoritative_source: mode == 'enforced' ? 'access_role' : 'legacy',
      access_role_resolution: access_role_resolution(account_user, capability, mode)
    )
  end

  def access_role_resolution(account_user, capability, mode)
    return if mode == 'legacy'

    AccessControl::ShadowResolver.call(
      account_user: account_user,
      resource: 'conversations',
      capability: capability
    )
  end
end
