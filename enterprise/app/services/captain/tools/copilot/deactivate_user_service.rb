# frozen_string_literal: true

class Captain::Tools::Copilot::DeactivateUserService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'deactivate_user'
  end

  description 'Deactivate an account user by removing their account membership, team memberships, and inbox memberships'
  param :user_id, type: :number, desc: 'Account user ID to deactivate', required: true

  def execute(user_id:)
    ensure_account_administrator!

    account_user = account_user!(user_id)
    user = account_user.user
    ensure_user_can_be_deactivated!(account_user, user)

    removed_membership_ids = remove_account_memberships!(account_user, user)
    formatted_payload(action: 'deactivate_user', deactivated_user: member_payload(user), **removed_membership_ids)
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def ensure_user_can_be_deactivated!(account_user, user)
    ensure_not_current_user!(user)
    ensure_not_last_admin!(account_user)
  end

  def remove_account_memberships!(account_user, user)
    team_ids = team_ids_for(user.id)
    inbox_ids = inbox_ids_for(user.id)

    ActiveRecord::Base.transaction do
      TeamMember.joins(:team).where(teams: { account_id: account.id }, user_id: user.id).destroy_all
      InboxMember.joins(:inbox).where(inboxes: { account_id: account.id }, user_id: user.id).destroy_all
      account_user.destroy!
    end

    { removed_team_ids: team_ids, removed_inbox_ids: inbox_ids }
  end

  def inbox_ids_for(user_id)
    InboxMember.joins(:inbox).where(inboxes: { account_id: account.id }, user_id: user_id).pluck(:inbox_id)
  end
end
