class Api::V1::Accounts::Scheduling::AppointmentPaymentsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :ensure_finance_enabled!
  before_action :set_appointment
  before_action :authorize_appointment_finance!

  def create
    appointment = Scheduling::Appointments::FinanceSyncService.new(
      appointment: @appointment,
      actor: Current.user
    ).add_payment!(
      amount: payment_params[:amount],
      payment_method: payment_params[:payment_method]
    )

    render_payload(appointment_payload(appointment))
  end

  def destroy
    appointment = Scheduling::Appointments::FinanceSyncService.new(
      appointment: @appointment,
      actor: Current.user
    ).cancel_all!

    render_payload(appointment_payload(appointment))
  end

  private

  def payment_params
    params.permit(:amount, :payment_method)
  end

  def set_appointment
    @appointment = appointment_scope.includes(:payments, :expense, :resource).find(params[:appointment_id] || params[:id])
  end

  def appointment_scope
    Scheduling::AppointmentPolicy::Scope.new(
      pundit_user,
      Current.account.scheduling_appointments,
      capability: 'manage_finance'
    ).resolve
  end

  def authorize_appointment_finance!
    authorize @appointment, :manage_finance_legacy?
  end

  def appointment_payload(appointment)
    Scheduling::PayloadBuilder.appointment(
      appointment,
      include_finance: Scheduling::AppointmentPolicy.new(pundit_user, appointment).view_finance_legacy?
    )
  end
end
