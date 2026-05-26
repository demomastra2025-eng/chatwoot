class Api::V1::Accounts::Scheduling::ResourcesController < Api::V1::Accounts::Scheduling::BaseController
  TERMINAL_APPOINTMENT_STATUSES = %w[completed cancelled no_show].freeze
  BLOCKING_APPOINTMENT_STATUSES = (Scheduling::Constants::APPOINTMENT_STATUSES - TERMINAL_APPOINTMENT_STATUSES).freeze
  BLOCKING_APPOINTMENT_DETAIL_LIMIT = 10

  before_action :check_admin_authorization?, except: [:index, :show]
  before_action :set_resource, only: [:show, :update, :destroy]

  def index
    resources = Current.account.scheduling_resources.ordered
    resources = resources.active unless parse_boolean(params[:include_inactive])

    render_payload(
      resources.map { |resource| Scheduling::PayloadBuilder.resource(resource) },
      meta: { count: resources.size }
    )
  end

  def show
    render_payload(Scheduling::PayloadBuilder.resource(@scheduling_resource))
  end

  def create
    resource = Current.account.scheduling_resources.create!(resource_params)
    render_payload(Scheduling::PayloadBuilder.resource(resource), status: :created)
  end

  def update
    @scheduling_resource.update!(resource_params)
    render_payload(Scheduling::PayloadBuilder.resource(@scheduling_resource))
  end

  def destroy
    ensure_destroyable_resource!
    @scheduling_resource.archive_from_scheduling!
    head :no_content
  end

  private

  def resource_params
    normalize_integer_numeric_params!(
      params.permit(
        :name,
        :specialty,
        :photo_url,
        :description,
        :color,
        :timezone,
        :slot_duration_min,
        :compensation_type,
        :compensation_value,
        :compensation_percent,
        :active,
        :user_id,
        custom_attributes: {}
      ),
      :slot_duration_min,
      :compensation_value,
      :compensation_percent
    )
  end

  def set_resource
    @scheduling_resource = Current.account.scheduling_resources.find(params[:id])
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
          payment_status: appointment.payment_status,
          starts_at: appointment.starts_at&.iso8601,
          ends_at: appointment.ends_at&.iso8601
        }
      end
    }
  end
end
