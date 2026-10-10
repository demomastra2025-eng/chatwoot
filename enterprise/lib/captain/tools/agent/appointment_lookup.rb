class Captain::Tools::Agent::AppointmentLookup
  MAX_RESULTS = 5

  def initialize(assistant:, conversation:, params:)
    @assistant = assistant
    @conversation = conversation
    @params = params
  end

  def perform
    raise ArgumentError, 'Current conversation is not available' unless conversation&.account_id == assistant.account_id

    scope = assistant.account.scheduling_appointments.includes(:resource)
    scope = identified_scope(scope)
    scope = scope.where(resource_id: params[:resource_id]) if params[:resource_id].present?
    status = params[:status].presence || (%w[scheduled confirmed] if params[:from].blank?)
    scope = scope.where(status: status) if status.present?
    from, to = range
    scope = scope.where('starts_at >= ? AND starts_at < ?', from, to)
    records = scope.order(:starts_at, :id).limit(MAX_RESULTS + 1).to_a
    {
      success: true,
      appointments: records.first(MAX_RESULTS).map { |appointment| result(appointment) },
      has_more: records.size > MAX_RESULTS,
      clarification_required: records.size > MAX_RESULTS
    }
  end

  private

  attr_reader :assistant, :conversation, :params

  def identified_scope(scope)
    if params[:client_identifier].present?
      identifier = Scheduling::IinValidator.normalize(params[:client_identifier])
      raise ArgumentError, 'Invalid IIN' unless Scheduling::IinValidator.valid?(identifier)

      scope.where("regexp_replace(client_identifier, '[^0-9]', '', 'g') = ?", identifier)
    else
      name = params[:client_name].to_s.strip.gsub(/\s+/, ' ').downcase
      raise ArgumentError, 'Provide the exact patient name, doctor and appointment date' unless name.split.size >= 2 &&
                                                                                              params[:resource_id].present? && params[:from].present?

      scope.where("regexp_replace(trim(lower(client_name)), '\\s+', ' ', 'g') = ?", name)
    end
  end

  def range
    @range ||= if params[:from].present?
                 from = Time.zone.parse(params[:from].to_s)
                 to = params[:to].present? ? Time.zone.parse(params[:to].to_s) : from&.+(1.day)
                 raise ArgumentError, 'Appointment lookup requires a valid range of at most one day' unless from && to &&
                                                                                                          to > from && to - from <= 1.day

                 [from, to]
               else
                 # An IIN alone locates upcoming appointments for this task; it
                 # does not expose a patient's past visit history.
                 scope_start = Time.current
                 [scope_start, scope_start + 90.days]
               end
  end

  def result(appointment)
    Captain::Tools::Agent::AppointmentResult.appointment(appointment).merge(
      patient_name: appointment.client_name,
      appointment_access_token: Captain::Tools::Agent::AppointmentAccess.issue(
        assistant: assistant, conversation: conversation, appointment: appointment
      )
    )
  end
end
