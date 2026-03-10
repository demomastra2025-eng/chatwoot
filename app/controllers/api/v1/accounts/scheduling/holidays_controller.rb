class Api::V1::Accounts::Scheduling::HolidaysController < Api::V1::Accounts::Scheduling::BaseController
  before_action :check_admin_authorization?, except: [:index]
  before_action :set_holiday, only: [:update, :destroy]

  def index
    holidays = Current.account.scheduling_holidays.ordered
    holidays = holidays.where(date: Date.new(params[:year].to_i, 1, 1).all_year) if params[:year].present?

    render_payload(holidays.map { |holiday| Scheduling::PayloadBuilder.holiday(holiday) }, meta: { count: holidays.size })
  end

  def create
    holiday = Current.account.scheduling_holidays.create!(holiday_params)
    render_payload(Scheduling::PayloadBuilder.holiday(holiday), status: :created)
  end

  def update
    @holiday.update!(holiday_params)
    render_payload(Scheduling::PayloadBuilder.holiday(@holiday))
  end

  def destroy
    @holiday.destroy!
    head :no_content
  end

  private

  def holiday_params
    params.permit(:date, :title, :recurring_yearly, :working_day_override, custom_attributes: {})
  end

  def set_holiday
    @holiday = Current.account.scheduling_holidays.find(params[:id])
  end
end
