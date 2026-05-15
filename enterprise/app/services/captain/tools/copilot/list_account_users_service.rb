# frozen_string_literal: true

class Captain::Tools::Copilot::ListAccountUsersService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_account_users'
  end

  description 'List account users available to the operator assistant for assignment, notifications, and ownership fields'
  param :query, type: :string, desc: 'Optional partial match against user name or email', required: false
  param :role, type: :string, desc: 'Optional account role filter: agent or administrator', required: false
  param :availability, type: :string, desc: 'Optional availability filter: online, offline, or busy', required: false
  param :limit, type: :number, desc: 'Maximum number of users to return', required: false

  def execute(query: nil, role: nil, availability: nil, limit: nil)
    account_users = filtered_account_users(query: query, role: role, availability: availability)
    records = account_users.limit(parse_limit(limit)).map { |account_user| user_payload(account_user) }

    formatted_payload(filters: { query: query, role: role, availability: availability }.compact, total_count: account_users.count, users: records)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    operator_can_view_account_people?
  end

  private

  def operator_can_view_account_people?
    account_administrator? || account_people_directory_permission?
  end

  def filtered_account_users(query:, role:, availability:)
    scope = account.account_users.includes(:user, :custom_role).order(:role, :user_id)
    if query.present?
      scope = scope.joins(:user).where(
        'LOWER(users.name) ILIKE :query OR LOWER(users.email) ILIKE :query',
        query: "%#{query.to_s.downcase}%"
      )
    end
    scope = scope.where(role: role) if role.present?
    scope = scope.where(availability: availability) if availability.present?
    scope
  end

  def account_people_directory_permission?
    permissions = Array(current_account_user&.custom_role&.permissions)
    permissions.any? do |permission|
      %w[
        conversation_manage
        crm_deal_manage
        crm_task_manage
        crm_settings_manage
      ].include?(permission)
    end
  end

  def user_payload(account_user)
    user = account_user.user

    {
      id: user.id,
      name: user.name,
      display_name: user.display_name,
      email: user.email,
      role: account_user.role,
      availability: account_user.availability,
      auto_offline: account_user.auto_offline,
      custom_role_id: account_user.custom_role_id,
      custom_role_name: account_user.custom_role&.name,
      team_ids: team_ids_for(user.id),
      active_at: account_user.active_at&.iso8601
    }.compact
  end

  def team_ids_for(user_id)
    team_members_by_user_id.fetch(user_id, [])
  end

  def team_members_by_user_id
    @team_members_by_user_id ||= TeamMember.joins(:team)
                                           .where(teams: { account_id: account.id })
                                           .pluck(:user_id, :team_id)
                                           .group_by(&:first)
                                           .transform_values { |pairs| pairs.map(&:second) }
  end
end
