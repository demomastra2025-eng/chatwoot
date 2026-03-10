class Api::V1::Accounts::Scheduling::ResourcesController < Api::V1::Accounts::Scheduling::BaseController
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
    render_payload(Scheduling::PayloadBuilder.resource(@resource))
  end

  def create
    resource = Current.account.scheduling_resources.create!(resource_params)
    render_payload(Scheduling::PayloadBuilder.resource(resource), status: :created)
  end

  def update
    @resource.update!(resource_params)
    render_payload(Scheduling::PayloadBuilder.resource(@resource))
  end

  def destroy
    @resource.destroy!
    head :no_content
  end

  private

  def resource_params
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
      :active,
      :user_id,
      custom_attributes: {}
    )
  end

  def set_resource
    @resource = Current.account.scheduling_resources.find(params[:id])
  end
end
