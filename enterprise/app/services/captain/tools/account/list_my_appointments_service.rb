class Captain::Tools::Account::ListMyAppointmentsService < Captain::Tools::Account::BaseAccountTool
  def self.name
    'list_my_appointments'
  end

  description 'List the appointments booked from the chat of the current conversation contact (the contact and any child or relative ' \
              'booked here) with filters and pagination'
  param :status, type: :string, desc: 'scheduled, completed, cancelled, no_show, or any', required: false
  param :date_from, type: :string, desc: 'Start date in YYYY-MM-DD', required: false
  param :date_to, type: :string, desc: 'End date in YYYY-MM-DD', required: false
  param :doctor, type: :string, desc: 'Part of doctor name', required: false
  param :limit, type: :number, desc: 'Page size, at most 20', required: false
  param :offset, type: :number, desc: 'Number of records to skip', required: false

  def execute(**filters)
    return formatted_payload(success: false, reason: 'not_found') if current_contact.blank?

    context = Captain::AppointmentContext.new(account: account, conversation: current_conversation)
    formatted_payload(with_access_tokens(context.list(**filters)))
  rescue StandardError => e
    formatted_payload(Captain::Tools::Agent::AppointmentResult.failure(e))
  end

  def active?
    @user.present? && account.feature_enabled?('scheduling')
  end

  private

  # The card of an appointment of another patient (it names the patient) carries the task token that changing or cancelling it needs,
  # as the cards of search_appointments do: one access rule for the visits of a family, whichever lookup found them.
  def with_access_tokens(payload)
    cards = Array(payload[:appointments])
    other = cards.select { |card| card.key?(:patient_name) }
    return payload if other.empty?

    records = account.scheduling_appointments.where(id: other.pluck(:id)).index_by(&:id)
    tokened = cards.map do |card|
      record = records[card[:id]]
      next card unless card.key?(:patient_name) && record

      card.merge(appointment_access_token: Captain::Tools::Agent::AppointmentAccess.issue(
        assistant: assistant, conversation: current_conversation, appointment: record
      ))
    end
    payload.merge(appointments: tokened)
  end
end
