class Captain::Tools::Copilot::ListMyAppointmentsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_my_appointments'
  end

  description 'List appointments of the current conversation contact with filters and pagination'
  param :status, type: :string, desc: 'scheduled, completed, cancelled, no_show, or any', required: false
  param :date_from, type: :string, desc: 'Start date in YYYY-MM-DD', required: false
  param :date_to, type: :string, desc: 'End date in YYYY-MM-DD', required: false
  param :doctor, type: :string, desc: 'Part of doctor name', required: false
  param :limit, type: :number, desc: 'Page size, at most 20', required: false
  param :offset, type: :number, desc: 'Number of records to skip', required: false

  def execute(**filters)
    return formatted_payload(success: false, reason: 'not_found') if current_contact.blank?

    context = Captain::AppointmentContext.new(account: account, conversation: current_conversation)
    formatted_payload(context.list(**filters))
  rescue StandardError => e
    formatted_payload(Captain::Tools::Agent::AppointmentResult.failure(e))
  end

  def active?
    @user.present? && account.feature_enabled?('scheduling')
  end
end
