# frozen_string_literal: true

class Captain::Tools::Copilot::ReactivateUserService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'reactivate_user'
  end

  description 'Reactivate an existing user by lifecycle snapshot, user ID, or legacy email and restore their saved workspace memberships'
  param :lifecycle_snapshot_id, type: :number, desc: 'Account-scoped lifecycle snapshot ID returned by deactivate_user', required: false
  param :user_id, type: :number, desc: 'Stable user ID returned by deactivate_user', required: false
  param :email, type: :string, desc: 'Legacy exact email lookup. Prefer lifecycle_snapshot_id or user_id.', required: false
  param :role, type: :string, desc: 'Optional account role override: agent or administrator. Defaults to the saved role, then agent.', required: false
  param :availability,
        type: :string,
        desc: 'Optional availability override: online, offline, or busy. Defaults to the saved availability, then offline.',
        required: false

  def execute(lifecycle_snapshot_id: nil, user_id: nil, email: nil, role: nil, availability: nil)
    ensure_account_administrator!

    identity = resolve_reactivation_identity!(lifecycle_snapshot_id: lifecycle_snapshot_id, user_id: user_id, email: email)
    result = reactivate_user(identity[:user], snapshot_id: identity[:snapshot]&.id, role: role, availability: availability)

    formatted_payload(
      action: result[:action],
      user: account_user_payload(result[:account_user].reload),
      lifecycle_snapshot_id: result[:snapshot]&.id || identity[:snapshot]&.id,
      workspace_restored: result[:snapshot].present?,
      restored_team_ids: result[:restored_team_ids],
      restored_inbox_ids: result[:restored_inbox_ids],
      reactivation_source: identity[:source],
      idempotent_replay: result[:action] == 'reactivate_user_already_active'
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def resolve_reactivation_identity!(lifecycle_snapshot_id:, user_id:, email:)
    identifiers = [lifecycle_snapshot_id, user_id, email].count(&:present?)
    raise ArgumentError, 'Provide exactly one of lifecycle_snapshot_id, user_id, or email' unless identifiers == 1

    return identity_from_snapshot_id!(lifecycle_snapshot_id) if lifecycle_snapshot_id.present?
    return identity_from_user_id!(user_id) if user_id.present?

    identity_from_email!(email)
  end

  def identity_from_snapshot_id!(snapshot_id)
    snapshot = AccountUserLifecycleSnapshot.find_by!(account: account, id: snapshot_id)

    { user: snapshot.user, snapshot: snapshot, source: 'lifecycle_snapshot_id' }
  end

  def identity_from_user_id!(user_id)
    snapshot = AccountUserLifecycleSnapshot.active.find_by(account: account, user_id: user_id)
    user = account.account_users.includes(:user).find_by(user_id: user_id)&.user || snapshot&.user
    raise ActiveRecord::RecordNotFound, 'Account user or lifecycle snapshot not found' if user.blank?

    { user: user, snapshot: snapshot, source: 'user_id' }
  end

  def identity_from_email!(email)
    raise ArgumentError, 'email is required' if email.blank?

    account_user = account.account_users.joins(:user).merge(User.where(email: email.to_s.downcase)).includes(:user).first
    snapshot = AccountUserLifecycleSnapshot.active.joins(:user).where(account: account, users: { email: email.to_s.downcase }).first
    user = account_user&.user || snapshot&.user || User.from_email(email)
    raise ActiveRecord::RecordNotFound, 'User not found' if user.blank?

    { user: user, snapshot: snapshot, source: snapshot.present? ? 'lifecycle_email' : 'legacy_global_email' }
  end

  def reactivate_user(user, snapshot_id:, role:, availability:)
    user.with_lock do
      snapshot_scope = AccountUserLifecycleSnapshot.active.lock.where(account: account, user: user)
      snapshot = snapshot_id.present? ? snapshot_scope.find_by(id: snapshot_id) : snapshot_scope.first
      account_user = account.account_users.find_by(user: user)

      if account_user.present? && snapshot.blank?
        already_active_result(account_user)
      else
        raise ActiveRecord::RecordNotFound, 'Active lifecycle snapshot not found' if snapshot_id.present? && snapshot.blank?

        account_user ||= create_account_user!(user, snapshot: snapshot, role: role, availability: availability)
        restored_memberships = restore_workspace_memberships!(user, snapshot)
        snapshot&.update!(reactivated_at: Time.current)

        { action: 'reactivate_user', account_user: account_user, snapshot: snapshot, **restored_memberships }
      end
    end
  end

  def create_account_user!(user, snapshot:, role:, availability:)
    normalized_role = role.presence || snapshot&.role || 'agent'
    normalized_availability = availability.presence || snapshot&.availability || 'offline'
    ensure_valid_role!(normalized_role)
    ensure_valid_availability!(normalized_availability)

    AccountUser.create!(
      account: account,
      user: user,
      inviter: @user,
      role: normalized_role,
      availability: normalized_availability,
      auto_offline: snapshot.nil? || snapshot.auto_offline,
      custom_role_id: restorable_custom_role_id(snapshot),
      agent_capacity_policy_id: restorable_capacity_policy_id(snapshot)
    )
  end

  def restore_workspace_memberships!(user, snapshot)
    return { restored_team_ids: [], restored_inbox_ids: [] } if snapshot.blank?

    team_ids = account.teams.where(id: snapshot.team_ids).pluck(:id)
    inbox_ids = account.inboxes.where(id: snapshot.inbox_ids).pluck(:id)
    team_ids.each { |team_id| TeamMember.find_or_create_by!(team_id: team_id, user_id: user.id) }
    inbox_ids.each { |inbox_id| InboxMember.find_or_create_by!(inbox_id: inbox_id, user_id: user.id) }

    { restored_team_ids: team_ids, restored_inbox_ids: inbox_ids }
  end

  def restorable_custom_role_id(snapshot)
    return if snapshot&.custom_role_id.blank?

    account.custom_roles.where(id: snapshot.custom_role_id).pick(:id)
  end

  def restorable_capacity_policy_id(snapshot)
    return if snapshot&.agent_capacity_policy_id.blank?

    account.agent_capacity_policies.where(id: snapshot.agent_capacity_policy_id).pick(:id)
  end

  def already_active_result(account_user)
    {
      action: 'reactivate_user_already_active',
      account_user: account_user,
      snapshot: nil,
      restored_team_ids: team_ids_for(account_user.user_id),
      restored_inbox_ids: inbox_ids_for(account_user.user_id)
    }
  end

  def inbox_ids_for(user_id)
    InboxMember.joins(:inbox).where(inboxes: { account_id: account.id }, user_id: user_id).pluck(:inbox_id)
  end
end
