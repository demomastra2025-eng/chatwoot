class Captain::Tools::Copilot::SearchAppointmentsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_appointments'
  end

  description 'Search appointments by client, status, payment status, contact, or specialist'
  param :client_name, type: :string, desc: 'Client name query', required: false
  param :status, type: :string, desc: 'Appointment status: scheduled, confirmed, completed, cancelled, or no_show', required: false
  param :payment_status, type: :string, desc: 'Payment status: awaiting_payment, prepaid, paid, or cancelled', required: false
  param :contact_id, type: :number, desc: 'Contact ID', required: false
  param :resource_id, type: :number, desc: 'Specialist resource ID', required: false
  param :from, type: :string, desc: 'Start of range datetime', required: false
  param :to, type: :string, desc: 'End of range datetime', required: false
  param :limit, type: :number, desc: 'Maximum number of appointments to return', required: false

  def execute(client_name: nil, status: nil, payment_status: nil, contact_id: nil, resource_id: nil, from: nil, to: nil, limit: nil)
    contact_id = verified_optional_record_id(contact_id, scope: account.contacts, field_name: 'contact_id')
    resource_id = verified_optional_record_id(resource_id, scope: account.scheduling_resources, field_name: 'resource_id')

    appointments = account.scheduling_appointments.includes(
      :resource,
      :service,
      :company,
      :contact,
      conversation: [:inbox, :communication_thread]
    )
    appointments = appointments.where(contact_id: contact_id) if contact_id.present?
    appointments = appointments.where(resource_id: resource_id) if resource_id.present?
    appointments = appointments.where(status: status) if status.present?
    appointments = appointments.where(payment_status: payment_status) if payment_status.present?
    appointments = appointments.where('LOWER(client_name) ILIKE ?', "%#{client_name.to_s.downcase}%") if client_name.present?

    range_from = parse_datetime(from, field_name: 'from', required: false)
    range_to = parse_datetime(to, field_name: 'to', required: false)
    appointments = appointments.where('starts_at >= ?', range_from) if range_from.present?
    appointments = appointments.where('starts_at < ?', range_to) if range_to.present?

    total_count = appointments.count
    records = appointment_records(appointments, limit: parse_limit(limit), include_client_name: client_name.present?)

    formatted_payload(
      filters: {
        client_name: client_name,
        status: status,
        payment_status: payment_status,
        contact_id: contact_id,
        resource_id: resource_id,
        from: from,
        to: to
      }.compact,
      total_count: total_count,
      appointments: records
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def appointment_records(appointments, limit:, include_client_name:)
    appointments.order(starts_at: :desc, id: :desc).limit(limit).map do |appointment|
      appointment_payload(appointment, include_client_name: include_client_name)
    end
  end

  def appointment_payload(appointment, include_client_name:)
    payload = Scheduling::PayloadBuilder.appointment(appointment).except(
      :client_phone,
      :client_identifier,
      :client_birth_date,
      :client_gender,
      :client_comment
    )
    include_client_name ? payload : payload.except(:client_name)
  end
end
