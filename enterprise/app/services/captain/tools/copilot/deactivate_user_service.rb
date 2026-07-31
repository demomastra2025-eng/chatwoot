# frozen_string_literal: true

class Captain::Tools::Copilot::DeactivateUserService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'deactivate_user'
  end

  description 'Deactivate an account user while saving a restorable snapshot of their account, team, and inbox memberships'
  param :user_id, type: :number, desc: 'Stable user ID to deactivate in this account', required: true

  def execute(user_id:)
    ensure_account_administrator!

    result = deactivate_account_user(user_id)
    action = result[:idempotent_replay] ? 'deactivate_user_already_inactive' : 'deactivate_user'

    formatted_payload(
      action: action,
      deactivated_user: member_payload(result[:snapshot].user),
      user_id: result[:snapshot].user_id,
      lifecycle_snapshot_id: result[:snapshot].id,
      deactivated_at: result[:snapshot].deactivated_at.iso8601,
      removed_team_ids: result[:snapshot].team_ids,
      removed_inbox_ids: result[:snapshot].inbox_ids,
      idempotent_replay: result[:idempotent_replay]
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def ensure_user_can_be_deactivated!(account_user, user)
    ensure_not_current_user!(user)
    ensure_not_last_admin!(account_user)
  end

  def deactivate_account_user(user_id)
    account_user = account.account_users.includes(:user).find_by(user_id: user_id)
    return replay_snapshot!(user_id) if account_user.blank?

    user = account_user.user
    user.with_lock do
      account_user = account.account_users.find_by(user_id: user.id)
      if account_user.blank?
        replay_snapshot!(user.id)
      else
        ensure_user_can_be_deactivated!(account_user, user)
        snapshot = create_lifecycle_snapshot!(account_user, user)
        TeamMember.joins(:team).where(teams: { account_id: account.id }, user_id: user.id).destroy_all
        InboxMember.joins(:inbox).where(inboxes: { account_id: account.id }, user_id: user.id).destroy_all
        account_user.destroy!

        { snapshot: snapshot, idempotent_replay: false }
      end
    end
  end

  def create_lifecycle_snapshot!(account_user, user)
    snapshot = AccountUserLifecycleSnapshot.active.find_or_initialize_by(account: account, user: user)
    snapshot.update!(
      account: account,
      user: user,
      deactivated_by: @user,
      role: account_user.role,
      availability: account_user.availability,
      auto_offline: account_user.auto_offline,
      custom_role_id: account_user.custom_role_id,
      agent_capacity_policy_id: account_user.agent_capacity_policy_id,
      team_ids: team_ids_for(user.id),
      inbox_ids: inbox_ids_for(user.id),
      deactivated_at: Time.current
    )
    snapshot
  end

  def replay_snapshot!(user_id)
    snapshot = AccountUserLifecycleSnapshot.active.find_by(account: account, user_id: user_id)
    raise ActiveRecord::RecordNotFound, 'Active account user or deactivation snapshot not found' if snapshot.blank?

    { snapshot: snapshot, idempotent_replay: true }
  end

  def inbox_ids_for(user_id)
    InboxMember.joins(:inbox).where(inboxes: { account_id: account.id }, user_id: user_id).pluck(:inbox_id)
  end
end
