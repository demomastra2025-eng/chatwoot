# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateUserAvailabilityService < Captain::Tools::Copilot::AccountAdminPeopleTool
  def self.name
    'update_user_availability'
  end

  description 'Update an account user availability and optional auto-offline routing setting'
  param :user_id, type: :number, desc: 'User ID from list_account_users to update', required: true
  param :availability, type: :string, desc: 'Optional availability: online, offline, or busy', required: false
  param :auto_offline, type: :boolean, desc: 'Optional auto-offline toggle for assignment availability', required: false

  def execute(user_id:, availability: nil, auto_offline: nil)
    ensure_account_administrator!

    account_user = account_user!(user_id)
    attributes = availability_update_attributes(availability: availability, auto_offline: auto_offline)
    raise ArgumentError, 'No supported availability fields were provided' if attributes.blank?

    account_user.update!(attributes)

    formatted_payload(
      action: 'update_user_availability',
      user: account_user_payload(account_user.reload),
      updated_fields: attributes.keys.map(&:to_s)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def availability_update_attributes(availability:, auto_offline:)
    attributes = {}
    if availability.present?
      ensure_valid_availability!(availability)
      attributes[:availability] = availability
    end
    attributes[:auto_offline] = cast_boolean(auto_offline) unless auto_offline.nil?
    attributes
  end
end
