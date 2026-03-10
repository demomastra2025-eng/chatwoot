class Api::V1::Accounts::Scheduling::AppointmentPaymentsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :ensure_finance_enabled!
  before_action :set_appointment

  def create
    appointment = Scheduling::Appointments::FinanceSyncService.new(
      appointment: @appointment,
      actor: Current.user
    ).add_payment!(
      amount: payment_params[:amount],
      payment_method: payment_params[:payment_method]
    )

    render_payload(Scheduling::PayloadBuilder.appointment(appointment))
  end

  def destroy
    appointment = Scheduling::Appointments::FinanceSyncService.new(
      appointment: @appointment,
      actor: Current.user
    ).cancel_all!

    render_payload(Scheduling::PayloadBuilder.appointment(appointment))
  end

  private

  def payment_params
    params.permit(:amount, :payment_method)
  end

  def set_appointment
    @appointment = Current.account.scheduling_appointments.includes(:payments, :expense).find(params[:appointment_id] || params[:id])
  end
end
