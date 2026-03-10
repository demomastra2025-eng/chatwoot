class Api::V1::Accounts::Scheduling::AppointmentsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :set_appointment, only: [:show, :update, :cancel]

  def index
    appointments = Current.account.scheduling_appointments.includes(:payments, :expense).ordered
    appointments = filter_by_range(appointments)
    appointments = appointments.where(resource_id: parse_csv_ids(params[:resource_ids])) if params[:resource_ids].present?
    appointments = appointments.where(status: parse_csv_ids(params[:status])) if params[:status].present?
    appointments = appointments.where(payment_status: parse_csv_ids(params[:payment_status])) if params[:payment_status].present?

    render_payload(
      appointments.map { |appointment| Scheduling::PayloadBuilder.appointment(appointment) },
      meta: { count: appointments.size }
    )
  end

  def show
    render_payload(Scheduling::PayloadBuilder.appointment(@appointment))
  end

  def create
    existing_appointment = idempotent_appointment
    return render_payload(Scheduling::PayloadBuilder.appointment(existing_appointment), status: :ok) if existing_appointment.present?

    appointment = Scheduling::Appointments::UpsertService.new(
      account: Current.account,
      params: appointment_params,
      actor: Current.user
    ).perform

    render_payload(Scheduling::PayloadBuilder.appointment(appointment), status: :created)
  end

  def update
    appointment = Scheduling::Appointments::UpsertService.new(
      account: Current.account,
      params: appointment_params,
      appointment: @appointment,
      actor: Current.user
    ).perform

    render_payload(Scheduling::PayloadBuilder.appointment(appointment))
  end

  def cancel
    appointment = Scheduling::Appointments::UpsertService.new(
      account: Current.account,
      params: { status: 'cancelled', payment_status: 'cancelled' },
      appointment: @appointment,
      actor: Current.user
    ).perform

    render_payload(Scheduling::PayloadBuilder.appointment(appointment))
  end

  private

  def appointment_params
    params.permit(
      :resource_id,
      :contact_id,
      :service_id,
      :company_id,
      :conversation_id,
      :created_by_id,
      :starts_at,
      :ends_at,
      :duration_min,
      :status,
      :appointment_type,
      :client_name,
      :client_phone,
      :client_identifier,
      :client_birth_date,
      :client_gender,
      :client_comment,
      :source,
      :external_ref,
      :idempotency_key,
      :service_amount,
      :prepaid_amount,
      :prepaid_payment_method,
      :settlement_amount,
      :settlement_payment_method,
      :payment_status,
      custom_attributes: {}
    )
  end

  def filter_by_range(scope)
    from = parse_datetime_param!(params[:from], field_name: 'from', required: false)
    to = parse_datetime_param!(params[:to], field_name: 'to', required: false)
    return scope if from.blank? && to.blank?

    scoped = scope
    scoped = scoped.where('starts_at >= ?', from) if from.present?
    scoped = scoped.where('starts_at < ?', to) if to.present?
    scoped
  end

  def set_appointment
    @appointment = Current.account.scheduling_appointments.includes(:payments, :expense).find(params[:id])
  end

  def idempotent_appointment
    return if appointment_params[:idempotency_key].blank?

    Current.account.scheduling_appointments.includes(:payments, :expense).find_by(idempotency_key: appointment_params[:idempotency_key])
  end
end
