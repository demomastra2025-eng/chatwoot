class Api::V1::Accounts::Scheduling::TimeOffsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :check_admin_authorization?, except: [:index]
  before_action :set_time_off, only: [:update, :destroy]

  def index
    time_offs = Current.account.scheduling_time_offs.ordered
    time_offs = time_offs.where(resource_id: params[:resource_id]) if params[:resource_id].present?

    from = parse_datetime_param!(params[:from], field_name: 'from', required: false)
    to = parse_datetime_param!(params[:to], field_name: 'to', required: false)
    time_offs = time_offs.where('starts_at >= ?', from) if from.present?
    time_offs = time_offs.where('starts_at < ?', to) if to.present?

    render_payload(time_offs.map { |item| Scheduling::PayloadBuilder.time_off(item) }, meta: { count: time_offs.size })
  end

  def create
    time_off = Current.account.scheduling_time_offs.create!(time_off_params)
    render_payload(Scheduling::PayloadBuilder.time_off(time_off), status: :created)
  end

  def update
    @time_off.update!(time_off_params)
    render_payload(Scheduling::PayloadBuilder.time_off(@time_off))
  end

  def destroy
    @time_off.destroy!
    head :no_content
  end

  private

  def set_time_off
    @time_off = Current.account.scheduling_time_offs.find(params[:id])
  end

  def time_off_params
    params.permit(:resource_id, :kind, :starts_at, :ends_at, :title, :notes, custom_attributes: {})
  end
end
