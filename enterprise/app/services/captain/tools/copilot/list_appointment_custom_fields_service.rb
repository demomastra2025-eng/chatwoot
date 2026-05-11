class Captain::Tools::Copilot::ListAppointmentCustomFieldsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_appointment_custom_fields'
  end

  description 'List active allowed CRM custom fields for appointment custom_attributes, including key, label, type, ' \
              'required flag, and select options.'

  def execute
    fields = Captain::Tools::CrmCustomFieldCatalog.new(
      account: account,
      entity_kind: 'appointment',
      context: 'booking_intake'
    ).fields

    formatted_payload(
      action: 'list_appointment_custom_fields',
      entity_kind: 'appointment',
      returned_count: fields.length,
      fields: fields
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('scheduling') && readable_or_manageable?
  end

  private

  def readable_or_manageable?
    case 'appointment'
    when 'deal'
      user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage')
    when 'task'
      user_has_permission('crm_task_view') || user_has_permission('crm_task_manage')
    else
      @user.present?
    end
  end
end
