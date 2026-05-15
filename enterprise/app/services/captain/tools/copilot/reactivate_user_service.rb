# frozen_string_literal: true

class Captain::Tools::Copilot::ReactivateUserService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'reactivate_user'
  end

  description 'Reactivate an existing user in this account by email, or report the account membership if already active'
  param :email, type: :string, desc: 'Exact email address of an existing user to reactivate in the account', required: true
  param :role, type: :string, desc: 'Account role: agent or administrator. Defaults to agent', required: false
  param :availability, type: :string, desc: 'Initial availability: online, offline, or busy. Defaults to offline', required: false

  def execute(email:, role: 'agent', availability: 'offline')
    ensure_account_administrator!

    user = find_user_by_email!(email)
    account_user = account.account_users.find_by(user_id: user.id)

    return formatted_payload(action: 'reactivate_user_already_active', user: account_user_payload(account_user.reload)) if account_user

    account_user = create_account_user!(user, role: role, availability: availability)
    formatted_payload(action: 'reactivate_user', user: account_user_payload(account_user.reload))
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def find_user_by_email!(email)
    raise ArgumentError, 'email is required' if email.blank?

    User.from_email(email) || raise(ActiveRecord::RecordNotFound, 'User not found')
  end

  def create_account_user!(user, role:, availability:)
    normalized_role = role.presence || 'agent'
    normalized_availability = availability.presence || 'offline'
    ensure_valid_role!(normalized_role)
    ensure_valid_availability!(normalized_availability)

    AccountUser.create!(
      account: account,
      user: user,
      inviter: @user,
      role: normalized_role,
      availability: normalized_availability
    )
  end
end
