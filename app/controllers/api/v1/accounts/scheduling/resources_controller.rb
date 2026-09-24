class Api::V1::Accounts::Scheduling::ResourcesController < Api::V1::Accounts::Scheduling::BaseController
  TERMINAL_APPOINTMENT_STATUSES = %w[completed cancelled no_show].freeze
  BLOCKING_APPOINTMENT_STATUSES = (Scheduling::Constants::APPOINTMENT_STATUSES - TERMINAL_APPOINTMENT_STATUSES).freeze
  BLOCKING_APPOINTMENT_DETAIL_LIMIT = 10

  before_action :check_admin_authorization?, except: [:index, :show]
  before_action :set_resource, only: [:show, :update, :destroy]
  before_action :ensure_provider_writable_resource!, only: [:update]
  before_action :validate_provider_owned_attributes!, only: [:create, :update]

  def index
    resources = Current.account.scheduling_resources.ordered
    resources = resources.active unless parse_boolean(params[:include_inactive])

    render_payload(
      resources.map { |resource| resource_payload(resource) },
      meta: { count: resources.size }
    )
  end

  def show
    render_payload(resource_payload(@scheduling_resource))
  end

  def create
    resource = Scheduling::Resource.transaction do
      attributes = resource_params
      created_resource = Current.account.scheduling_resources.create!(attributes)
      created_resource.apply_workspace_working_hours! if created_resource.inherit_working_hours_from_account?
      created_resource
    end
    render_payload(resource_payload(resource), status: :created)
  end

  def update
    @scheduling_resource.with_lock do
      @scheduling_resource.reload
      @scheduling_resource.update!(resource_params)
      @scheduling_resource.apply_workspace_working_hours! if @scheduling_resource.inherit_working_hours_from_account?
    end
    render_payload(resource_payload(@scheduling_resource))
  end

  def destroy
    ensure_destroyable_resource!
    @scheduling_resource.archive_from_scheduling!
    head :no_content
  end

  private

  def resource_payload(resource)
    Scheduling::PayloadBuilder.resource(resource)
  end

  def resource_params
    normalize_integer_numeric_params!(
      params.permit(
        :name,
        :specialty,
        :photo_url,
        :description,
        :color,
        :slot_duration_min,
        :inherit_working_hours_from_account,
        :active,
        :user_id,
        :team_id,
        custom_attributes: {}
      ),
      :slot_duration_min
    )
  end

  def set_resource
    @scheduling_resource = Current.account.scheduling_resources.find(params[:id])
  end

  def validate_provider_owned_attributes!
    incoming = params.permit(custom_attributes: {})[:custom_attributes]
    Integrations::Medelement::ProviderOwnedAttributesGuard.validate!(
      incoming: incoming,
      current: @scheduling_resource&.custom_attributes
    )
  end

  def ensure_provider_writable_resource!
    return if @scheduling_resource.custom_attributes['medelement_specialist_code'].blank?

    raise Scheduling::Error.new(
      code: 'RESOURCE_READ_ONLY',
      message: 'Imported Medelement specialists cannot be modified because the provider API does not support specialist writes',
      status: :unprocessable_content
    )
  end

  def ensure_destroyable_resource!
    if @scheduling_resource.custom_attributes['medelement_specialist_code'].present?
      raise Scheduling::Error.new(
        code: 'RESOURCE_READ_ONLY',
        message: 'Imported Medelement specialists cannot be deleted',
        status: :unprocessable_content
      )
    end

    return if @scheduling_resource.deleted_from_scheduling?

    blocking_appointments = blocking_appointments_for_destroy
    return if blocking_appointments.blank?

    raise Scheduling::Error.new(
      code: 'RESOURCE_HAS_APPOINTMENTS',
      message: 'Specialist with current or future active appointments cannot be deleted',
      status: :unprocessable_content,
      details: blocking_appointments_details(blocking_appointments)
    )
  end

  def blocking_appointments_for_destroy
    @scheduling_resource.appointments
                        .where(status: BLOCKING_APPOINTMENT_STATUSES)
                        .where(ends_at: Time.current..)
                        .ordered
  end

  def blocking_appointments_details(appointments)
    limited_appointments = appointments.limit(BLOCKING_APPOINTMENT_DETAIL_LIMIT)

    {
      blocking_appointment_count: appointments.count,
      blocking_appointments: limited_appointments.map do |appointment|
        {
          id: appointment.id,
          status: appointment.status,

          starts_at: appointment.starts_at&.iso8601,
          ends_at: appointment.ends_at&.iso8601
        }
      end
    }
  end
end
