class Api::V1::Accounts::Scheduling::AppointmentsController < Api::V1::Accounts::Scheduling::BaseController
  APPOINTMENT_PARAM_KEYS = %i[
    resource_id
    contact_id
    service_id
    company_id
    conversation_id
    conversation_display_id
    created_by_id
    owner_id
    starts_at
    ends_at
    duration_min
    status
    appointment_type
    client_first_name
    client_last_name
    client_middle_name
    client_name
    client_phone
    client_identifier
    client_birth_date
    client_gender
    client_comment
    external_ref
    idempotency_key
    service_name_snapshot
    service_amount
    prepaid_amount
    prepaid_payment_method
    settlement_amount
    settlement_payment_method
    payment_status
  ].freeze

  before_action :set_appointment, only: [:show, :update, :cancel, :create_conversation, :destroy]
  before_action :ensure_editable_appointment!, only: [:update, :cancel, :destroy]
  before_action :ensure_destroyable_appointment!, only: [:destroy]

  def index
    appointments = filtered_appointments
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

  def create_conversation
    inbox = Current.account.inboxes.find(create_conversation_params[:inbox_id])
    authorize inbox, :show?
    appointment = Scheduling::Appointments::CreateConversationService.new(
      account: Current.account,
      appointment: @appointment,
      inbox: inbox,
      params: create_conversation_params,
      actor: Current.user
    ).perform

    render_payload(Scheduling::PayloadBuilder.appointment(appointment))
  end

  def destroy
    @appointment.destroy!
    head :no_content
  end

  private

  def appointment_params
    params.permit(*APPOINTMENT_PARAM_KEYS, service_ids: [], custom_attributes: {})
  end

  def create_conversation_params
    params.permit(:contact_id, :contact_inbox_id, :inbox_id, :source_id)
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

  def filter_by_csv(scope, column, value)
    return scope if value.blank?

    scope.where(column => parse_csv_ids(value))
  end

  def filter_by_conversation_display_ids(scope)
    return scope if params[:conversation_display_ids].blank?

    conversation_ids = Current.account.conversations
                              .where(display_id: parse_csv_ids(params[:conversation_display_ids]))
                              .select(:id)
    scope.where(conversation_id: conversation_ids)
  end

  def filtered_appointments
    scope = appointments_with_payload_associations.ordered
    scope = filter_by_range(scope)
    scope = filter_by_reference_params(scope)
    scope = filter_by_status_params(scope)

    Scheduling::AppointmentCustomFieldFilterSet.new(
      account: Current.account,
      raw_filters: custom_attribute_filters_param
    ).apply(scope).to_a
  end

  def appointments_with_payload_associations
    Current.account.scheduling_appointments.includes(
      :payments,
      :expense,
      :contact,
      :resource,
      conversation: [:communication_thread, :inbox]
    )
  end

  def filter_by_reference_params(scope)
    scope = filter_by_csv(scope, :resource_id, params[:resource_ids])
    scope = filter_by_csv(scope, :contact_id, params[:contact_ids])
    scope = filter_by_csv(scope, :conversation_id, params[:conversation_ids])
    filter_by_conversation_display_ids(scope)
  end

  def filter_by_status_params(scope)
    scope = filter_by_csv(scope, :status, params[:status])
    filter_by_csv(scope, :payment_status, params[:payment_status])
  end

  def set_appointment
    @appointment = appointments_with_payload_associations.find(params[:id])
  end

  def idempotent_appointment
    return if appointment_params[:idempotency_key].blank?

    appointments_with_payload_associations.find_by(idempotency_key: appointment_params[:idempotency_key])
  end

  def ensure_editable_appointment!
    Scheduling::Appointments::MutationGuard.ensure_editable!(@appointment)
  end

  def ensure_destroyable_appointment!
    return if @appointment.status == 'cancelled'

    raise Scheduling::Error.new(
      code: 'APPOINTMENT_DELETE_REQUIRES_CANCELLED',
      message: 'Only cancelled appointments can be deleted',
      status: :unprocessable_content
    )
  end
end
