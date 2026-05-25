# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateUserRoleService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'update_user_role'
  end

  description 'Update an account user role or custom role. Use only after operator confirmation for role changes.'
  param :user_id, type: :number, desc: 'Account user ID to update', required: true
  param :role, type: :string, desc: 'Optional account role: agent or administrator', required: false
  param :custom_role_id, type: :number, desc: 'Optional account custom role ID to assign. Omit to leave unchanged.', required: false
  param :clear_custom_role, type: :boolean, desc: 'Set true to remove the current custom role from this user', required: false

  def execute(user_id:, role: nil, custom_role_id: nil, clear_custom_role: false)
    ensure_account_administrator!

    account_user = account_user!(user_id)
    attributes = role_update_attributes(account_user, role: role, custom_role_id: custom_role_id, clear_custom_role: clear_custom_role)
    raise ArgumentError, 'No supported user role fields were provided' if attributes.blank?

    account_user.update!(attributes)

    formatted_payload(
      action: 'update_user_role',
      user: account_user_payload(account_user.reload),
      updated_fields: attributes.keys.map(&:to_s)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def role_update_attributes(account_user, role:, custom_role_id:, clear_custom_role:)
    attributes = {}
    if role.present?
      ensure_valid_role!(role)
      ensure_not_last_admin!(account_user) if role.to_s == 'agent'
      attributes[:role] = role
    end

    if cast_boolean(clear_custom_role)
      attributes[:custom_role] = nil
    elsif custom_role_id.present?
      attributes[:custom_role] = custom_role_for(custom_role_id)
    end

    attributes
  end
end
