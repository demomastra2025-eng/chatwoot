class Captain::Tools::ListAppointmentCustomFieldsTool < Captain::Tools::BasePublicTool
  description 'List active allowed CRM custom fields for appointment custom_attributes, including key, label, type, ' \
              'required flag, and select options.'

  def perform(_tool_context)
    fields = Captain::Tools::CrmCustomFieldCatalog.new(
      account: account,
      entity_kind: 'appointment',
      context: 'booking_intake'
    ).fields

    JSON.pretty_generate(
      action: 'list_appointment_custom_fields',
      entity_kind: 'appointment',
      returned_count: fields.length,
      fields: fields
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('scheduling')
  end
end
