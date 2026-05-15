# frozen_string_literal: true

class Captain::Tools::Copilot::AccountAdminPeopleTool < Captain::Tools::Copilot::BaseAccountTool
  def active?
    account_administrator?
  end

  private

  def ensure_account_administrator!
    raise ArgumentError, 'Account administrator permission is required' unless account_administrator?
  end

  def account_user!(user_id)
    account.account_users.includes(:user, :custom_role).find_by!(user_id: user_id)
  end

  def account_user_for!(user)
    account.account_users.includes(:user, :custom_role).find_by!(user_id: user.id)
  end

  def account_user_payload(account_user)
    user = account_user.user

    {
      id: user.id,
      name: user.name,
      display_name: user.display_name,
      email: user.email,
      role: account_user.role,
      availability: account_user.availability,
      custom_role_id: account_user.custom_role_id,
      custom_role_name: account_user.custom_role&.name,
      team_ids: team_ids_for(user.id),
      active_at: account_user.active_at&.iso8601
    }.compact
  end

  def team_payload(team, include_members: true)
    payload = {
      id: team.id,
      name: team.name,
      description: team.description,
      allow_auto_assign: team.allow_auto_assign,
      created_at: team.created_at&.iso8601,
      updated_at: team.updated_at&.iso8601
    }.compact

    payload[:members] = team.members.map { |member| member_payload(member) } if include_members
    payload
  end

  def member_payload(user)
    { id: user.id, name: user.name, email: user.email }.compact
  end

  def ensure_valid_role!(role)
    return if AccountUser.roles.key?(role.to_s)

    raise ArgumentError, "role must be one of: #{AccountUser.roles.keys.join(', ')}"
  end

  def ensure_valid_availability!(availability)
    return if availability.blank? || AccountUser.availabilities.key?(availability.to_s)

    raise ArgumentError, "availability must be one of: #{AccountUser.availabilities.keys.join(', ')}"
  end

  def ensure_not_current_user!(target_user)
    raise ArgumentError, 'Cannot perform this action on the current operator user' if target_user.id == @user&.id
  end

  def ensure_not_last_admin!(target_account_user)
    return unless target_account_user.administrator?
    return if account.account_users.administrator.where.not(id: target_account_user.id).exists?

    raise ArgumentError, 'Cannot remove or demote the last account administrator'
  end

  def teams_for_ids!(value)
    ids = parse_id_list(value, field_name: 'team_ids')
    return [] if ids.blank?

    teams = account.teams.where(id: ids).to_a
    missing = ids - teams.map(&:id)
    raise ActiveRecord::RecordNotFound, "Account teams not found: #{missing.join(', ')}" if missing.any?

    teams
  end

  def team_ids_for(user_id)
    TeamMember.joins(:team).where(teams: { account_id: account.id }, user_id: user_id).pluck(:team_id)
  end

  def custom_role_for(value)
    return nil if value.blank?

    account.custom_roles.find(value)
  end
end
