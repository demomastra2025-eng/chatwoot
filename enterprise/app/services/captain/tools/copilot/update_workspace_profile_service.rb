# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateWorkspaceProfileService < Captain::Tools::Copilot::WorkspaceProfileTool
  def self.name
    'update_workspace_profile'
  end

  description 'Update the current OneLink workspace profile and safe account-level settings after operator confirmation'
  param :name, type: :string, desc: 'Optional workspace/company display name', required: false
  param :locale, type: :string, desc: 'Optional workspace default locale, for example ru, en, or kk', required: false
  param :domain, type: :string, desc: 'Optional custom reply domain. Empty string clears the value', required: false
  param :support_email, type: :string, desc: 'Optional public support email. Empty string clears the configured value', required: false
  param :industry, type: :string, desc: 'Optional company industry custom attribute. Empty string clears the value', required: false
  param :company_size, type: :string, desc: 'Optional company size custom attribute. Empty string clears the value', required: false
  param :timezone, type: :string, desc: 'Optional company timezone custom attribute. Empty string clears the value', required: false
  param :reporting_timezone, type: :string, desc: 'Optional reporting timezone such as Asia/Almaty. Empty string clears the value', required: false
  param :auto_resolve_after, type: :number, desc: 'Optional auto-resolve duration in minutes. Empty value clears the setting', required: false
  param :auto_resolve_message, type: :string, desc: 'Optional auto-resolve message. Empty string clears the value', required: false
  param :auto_resolve_ignore_waiting, type: :boolean, desc: 'Optional toggle for auto-resolve ignoring waiting conversations', required: false
  param :auto_resolve_label, type: :string, desc: 'Optional label to apply when auto-resolving. Empty string clears the value', required: false
  param :scheduling_contact_required, type: :boolean, desc: 'Optional scheduling setting: require contact on appointment records', required: false
  param :scheduling_company_enabled, type: :boolean, desc: 'Optional scheduling setting: enable company on appointment records', required: false
  param :default_appointment_touch_plan_id,
        type: :number,
        desc: 'Optional default touch-plan ID for appointments. Empty value clears the setting',
        required: false
  param :default_deal_touch_plan_id,
        type: :number,
        desc: 'Optional default touch-plan ID for deals. Empty value clears the setting',
        required: false
  param :default_task_touch_plan_id,
        type: :number,
        desc: 'Optional default touch-plan ID for tasks. Empty value clears the setting',
        required: false

  def execute(**kwargs)
    ensure_account_administrator!

    updates = workspace_profile_update_attributes(kwargs)
    raise ArgumentError, 'No supported workspace profile fields were provided' unless supported_field_provided?(updates)

    apply_workspace_profile_updates!(updates)

    formatted_payload(
      action: 'update_workspace_profile',
      workspace: workspace_profile_payload,
      updated_fields: updated_workspace_fields(updates)
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
