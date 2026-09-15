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
    title
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
    confirm_outside_working_hours
    confirm_slot_conflict
    confirm_break_conflict
    confirm_global_closure
    override_reason
  ].freeze
  ASSIGNMENT_PARAM_KEYS = %i[resource_id contact_id owner_id].freeze
  ACTION_LOOKUP_CAPABILITIES = {
    'show' => ['view'],
    'create_conversation' => ['update_fields'],
    'cancel' => ['transition'],
    'destroy' => ['delete_archive']
  }.freeze
  FINANCE_PARAM_KEYS = %i[
    service_amount prepaid_amount prepaid_payment_method settlement_amount settlement_payment_method payment_status
  ].freeze

  before_action :set_appointment, only: [:show, :update, :cancel, :create_conversation, :destroy]
  before_action :authorize_appointment_index!, only: [:index]
  before_action :authorize_appointment_create!, only: [:create]
  before_action :authorize_appointment_update!, only: [:update]
  before_action :authorize_appointment_transition!, only: [:cancel]
  before_action :authorize_appointment_conversation!, only: [:create_conversation]
  before_action :authorize_appointment_destroy!, only: [:destroy]
  before_action :ensure_editable_appointment!, only: [:update, :cancel, :destroy]
  before_action :ensure_destroyable_appointment!, only: [:destroy]

  def index
    appointments = filtered_appointments
    @finance_visibility = appointment_finance_scope.where(id: appointments.map(&:id)).pluck(:id).index_with(true)
    render_payload(
      appointments.map { |appointment| appointment_payload(appointment) },
      meta: { count: appointments.size }
    )
  end

  def show
    render_payload(appointment_payload(@appointment))
  end

  def create
    existing_appointment = idempotent_appointment
    return render_payload(appointment_payload(existing_appointment), status: :ok) if existing_appointment.present?

    appointment = Scheduling::Appointments::UpsertService.new(
      account: Current.account,
      params: appointment_params,
      actor: Current.user,
      required_capabilities: create_capabilities
    ).perform

    render_payload(appointment_payload(appointment), status: :created)
  end

  def update
    appointment = Scheduling::Appointments::UpsertService.new(
      account: Current.account,
      params: appointment_params,
      appointment: @appointment,
      actor: Current.user,
      required_capabilities: required_update_capabilities
    ).perform

    render_payload(appointment_payload(appointment))
  end

  def cancel
    appointment = Scheduling::Appointments::UpsertService.new(
      account: Current.account,
      params: { status: 'cancelled', payment_status: 'cancelled' },
      appointment: @appointment,
      actor: Current.user
    ).perform

    render_payload(appointment_payload(appointment))
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

    render_payload(appointment_payload(appointment))
  end

  def destroy
    @appointment.destroy!
    head :no_content
  end

  private

  def appointment_payload(appointment)
    Scheduling::PayloadBuilder.appointment(appointment, include_finance: appointment_finance_visible?(appointment))
  end

  def appointment_finance_visible?(appointment)
    return @finance_visibility.key?(appointment.id) if defined?(@finance_visibility)

    Scheduling::AppointmentPolicy.new(pundit_user, appointment).view_finance_legacy?
  end

  def appointment_finance_scope
    Scheduling::AppointmentPolicy::Scope.new(
      pundit_user,
      Current.account.scheduling_appointments,
      capability: 'view_finance'
    ).resolve
  end

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

  def appointments_with_payload_associations(scope = appointment_scope)
    scope.includes(
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
    return scope if params[:payment_status].blank?

    scope.where(
      id: filter_by_csv(appointment_finance_scope, :payment_status, params[:payment_status]).select(:id)
    )
  end

  def set_appointment
    @appointment = appointments_with_payload_associations(appointment_lookup_scope).find(params[:id])
  end

  def appointment_scope(capability: 'view')
    Scheduling::AppointmentPolicy::Scope.new(
      pundit_user,
      Current.account.scheduling_appointments,
      capability: capability
    ).resolve
  end

  def authorize_appointment_index!
    authorize Scheduling::Appointment, :index?
  end

  def authorize_appointment_create!
    authorize Scheduling::Appointment, :create?
    authorize Scheduling::Appointment, :transition? if create_transition?
    authorize Scheduling::Appointment, :manage_finance_legacy? if finance_params?
  end

  def authorize_appointment_update!
    keys = appointment_params.keys.map(&:to_sym)
    authorize @appointment, :assign? if keys.intersect?(ASSIGNMENT_PARAM_KEYS)
    authorize @appointment, :transition? if keys.include?(:status)
    authorize @appointment, :manage_finance_legacy? if finance_params?
    authorize @appointment, :update? if ordinary_update_keys(keys).any?
  end

  def finance_params?
    appointment_params.keys.map(&:to_sym).intersect?(FINANCE_PARAM_KEYS)
  end

  def finance_capabilities
    finance_params? ? ['manage_finance'] : []
  end

  def create_capabilities
    ['create'] + (create_transition? ? ['transition'] : []) + finance_capabilities
  end

  def create_transition?
    appointment_params[:status].present? && appointment_params[:status] != 'scheduled'
  end

  def required_update_capabilities
    keys = appointment_params.keys.map(&:to_sym)
    capabilities = []
    capabilities << 'update_fields' if ordinary_update_keys(keys).any?
    capabilities << 'transition' if keys.include?(:status)
    capabilities + finance_capabilities
  end

  def ordinary_update_keys(keys)
    keys - ASSIGNMENT_PARAM_KEYS - FINANCE_PARAM_KEYS - [:status]
  end

  def appointment_lookup_scope
    base_scope = Current.account.scheduling_appointments
    appointment_lookup_capabilities.reduce(base_scope.none) do |combined, capability|
      combined.or(base_scope.where(id: appointment_scope(capability: capability).select(:id)))
    end
  end

  def appointment_lookup_capabilities
    return ACTION_LOOKUP_CAPABILITIES.fetch(action_name) if ACTION_LOOKUP_CAPABILITIES.key?(action_name)

    required_update_capabilities.tap do |capabilities|
      capabilities << 'assign' if appointment_params.keys.map(&:to_sym).intersect?(ASSIGNMENT_PARAM_KEYS)
      capabilities << 'update_fields' if capabilities.empty?
    end.uniq
  end

  def authorize_appointment_transition!
    authorize @appointment, :transition?
  end

  def authorize_appointment_conversation!
    authorize @appointment, :create_conversation?
  end

  def authorize_appointment_destroy!
    authorize @appointment, :destroy?
  end

  def idempotent_appointment
    return if appointment_params[:idempotency_key].blank?

    appointments_with_payload_associations(appointment_scope(capability: 'create'))
      .find_by(idempotency_key: appointment_params[:idempotency_key])
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
