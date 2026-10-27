# frozen_string_literal: true

# The patient data that a reply suggestion would otherwise read with tools, read once when the run starts and given to the prompt
# (Captain::AssistantPrompt): the patient card, what get_my_contact returns, and the upcoming appointments of the patient circle, with
# the ids that cancel and reschedule need. A tool call costs a model step (about 2.5 s); in the PROD profile of 27.10 the card was read
# by half of the suggestions.
#
# The circle is what Scheduling::PatientContextQuery#patients gives (the patient, the patients who share the phone, the patients the
# patient booked for), nobody else: an appointment of anyone outside it is never read, and one that someone outside it booked for a
# member is not read either (Captain::AppointmentContext#upcoming_of_patients). An appointment the agent's own tools can act on by id (the scope of
# Captain::Tools::Agent::PatientScope, the one cancel_appointment and update_appointment check) is `own`; one of another patient of the
# phone is shown by name only, because to change it the agent must find it first with search_appointments, which gives its access token.
#
# Each part is read only for an agent that has the tool it replaces (get_my_contact, list_my_appointments): the clinic decides what the
# agent may read of a patient. The tools stay for other dates, past and cancelled appointments, or a fresher card.
class Captain::ReplySuggestion::PatientPreload
  CARD_TOOL = 'get_my_contact'
  APPOINTMENTS_TOOL = 'list_my_appointments'
  # The same number of upcoming appointments as the appointment summary of the prompt (Captain::ContextSummary::APPOINTMENT_GROUPS).
  APPOINTMENT_LIMIT = Captain::ContextSummary::APPOINTMENT_GROUPS.dig(:upcoming, :limit)

  # { card: { first_name: ... }, appointments: [{ id:, date:, time:, doctor:, service:, status:, own:, for: }], appointments_total: 2 };
  # a part that is not read is missing; {} when the conversation has no patient.
  def self.build(assistant:, conversation:, tool_ids:)
    new(assistant: assistant, conversation: conversation, tool_ids: Array(tool_ids).map(&:to_s)).build
  end

  def initialize(assistant:, conversation:, tool_ids:)
    @assistant = assistant
    @conversation = conversation
    @tool_ids = tool_ids
  end

  def build
    return {} if contact.blank?

    data = {}
    data[:card] = Captain::Tools::Account::GetMyContactService.payload(contact).compact_blank if @tool_ids.include?(CARD_TOOL)
    data.merge!(appointments_data) if @tool_ids.include?(APPOINTMENTS_TOOL)
    data
  end

  private

  def account
    @assistant.account
  end

  def contact
    return @contact if defined?(@contact)

    @contact = account.contacts.find_by(id: @conversation&.contact_id)
  end

  def circle
    @circle ||= Scheduling::PatientContextQuery.new(account: account, contact: contact).patients
  end

  def appointments_data
    context = Captain::AppointmentContext.new(account: account, conversation: @conversation)
    records, total = context.upcoming_of_patients(circle.map(&:id), limit: APPOINTMENT_LIMIT)
    own_ids = own_appointment_ids(records)
    names = circle.index_by(&:id)
    entries = records.map do |record|
      own = own_ids.include?(record.id)
      context.card(record).merge(own: own, for: (patient_name(names[record.patient_contact_id || record.contact_id]) unless own)).compact
    end
    { appointments: entries, appointments_total: total }
  end

  # The appointments that the agent's own tools act on by id: the scope of the patient scope of the run.
  def own_appointment_ids(records)
    Captain::Tools::Agent::PatientScope.new(assistant: @assistant, conversation: @conversation).appointments
                                       .where(id: records.map(&:id)).pluck(:id)
  end

  def patient_name(card)
    [card&.name, card&.last_name].compact_blank.join(' ').presence
  end
end
