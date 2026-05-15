# frozen_string_literal: true

class Captain::Tools::Copilot::CreateUserInviteService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'create_user_invite'
  end

  description 'Invite or add an account user with a safe account role and optional team memberships'
  param :email, type: :string, desc: 'User email address to invite or add to the account', required: true
  param :name, type: :string, desc: 'Optional display name for a newly-created user', required: false
  param :role, type: :string, desc: 'Account role: agent or administrator. Defaults to agent', required: false
  param :availability, type: :string, desc: 'Initial availability: online, offline, or busy. Defaults to offline', required: false
  param :auto_offline, type: :boolean, desc: 'Whether the user should automatically go offline when inactive', required: false
  param :team_ids, type: :string, desc: 'Optional comma-separated account team IDs to assign after invite', required: false

  # rubocop:disable Metrics/ParameterLists
  def execute(email:, name: nil, role: 'agent', availability: 'offline', auto_offline: false, team_ids: nil)
    ensure_account_administrator!

    normalized_role = normalized_role(role)
    normalized_availability = normalized_availability(availability)
    ensure_email_available!(email)

    teams = teams_for_ids!(team_ids)
    user = build_user_invite!(email, name, normalized_role, normalized_availability, auto_offline)
    teams.each { |team| team.add_members([user.id]) }

    formatted_payload(action: 'create_user_invite', user: account_user_payload(account_user_for!(user)), assigned_team_ids: teams.map(&:id))
  rescue StandardError => e
    tool_failure(e)
  end
  # rubocop:enable Metrics/ParameterLists

  private

  def normalized_role(role)
    role.presence || 'agent'
  end

  def normalized_availability(availability)
    availability.presence || 'offline'
  end

  def ensure_email_available!(email)
    raise ArgumentError, 'email is required' if email.blank?

    existing_user = User.from_email(email)
    raise ArgumentError, 'User already belongs to this account' if existing_user.present? && account.account_users.exists?(user_id: existing_user.id)
  end

  def build_user_invite!(email, name, role, availability, auto_offline)
    ensure_valid_role!(role)
    ensure_valid_availability!(availability)

    AgentBuilder.new(
      email: email,
      name: name.presence || email.to_s.split('@').first,
      role: role,
      availability: availability,
      auto_offline: cast_boolean(auto_offline),
      inviter: @user,
      account: account
    ).perform
  end
end
