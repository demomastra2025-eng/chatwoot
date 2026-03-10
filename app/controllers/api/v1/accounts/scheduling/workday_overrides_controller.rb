class Api::V1::Accounts::Scheduling::WorkdayOverridesController < Api::V1::Accounts::Scheduling::BaseController
  before_action :check_admin_authorization?, except: [:index]
  before_action :set_workday_override, only: [:update, :destroy]

  def index
    overrides = Current.account.scheduling_workday_overrides.ordered
    overrides = overrides.where(resource_id: params[:resource_id]) if params[:resource_id].present?
    overrides = overrides.where(date: Date.iso8601(params[:from])..) if params[:from].present?
    overrides = overrides.where(date: ..Date.iso8601(params[:to])) if params[:to].present?

    render_payload(
      overrides.map { |item| Scheduling::PayloadBuilder.workday_override(item) },
      meta: { count: overrides.size }
    )
  end

  def create
    item = Current.account.scheduling_workday_overrides.create!(workday_override_params)
    render_payload(Scheduling::PayloadBuilder.workday_override(item), status: :created)
  end

  def update
    @workday_override.update!(workday_override_params)
    render_payload(Scheduling::PayloadBuilder.workday_override(@workday_override))
  end

  def destroy
    @workday_override.destroy!
    head :no_content
  end

  private

  def set_workday_override
    @workday_override = Current.account.scheduling_workday_overrides.find(params[:id])
  end

  def workday_override_params
    params.permit(
      :resource_id,
      :date,
      :start_minute,
      :end_minute,
      :break_start_minute,
      :break_end_minute,
      :break_title,
      custom_attributes: {}
    )
  end
end
