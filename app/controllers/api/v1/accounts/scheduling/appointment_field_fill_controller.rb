class Api::V1::Accounts::Scheduling::AppointmentFieldFillController < Api::V1::Accounts::Scheduling::BaseController
  def show
    stats = Scheduling::TemplateFieldFillStats.new(
      account: Current.account, field_ids: params[:field_ids]
    ).perform
    render json: stats
  end
end
