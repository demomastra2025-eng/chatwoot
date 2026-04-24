class Captain::Tools::Copilot::AddAppointmentPaymentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'add_appointment_payment'
  end

  description 'Add a payment to the appointment linked to the current conversation'
  param :payment_method, type: :string, desc: 'Payment method identifier', required: true
  param :amount, type: :number, desc: 'Optional payment amount in major currency units', required: false

  def execute(payment_method:, amount: nil)
    appointment = appointment_operations.add_payment_to_current_appointment(amount: amount, payment_method: payment_method)

    formatted_payload(
      action: 'add_appointment_payment',
      appointment: ::Scheduling::PayloadBuilder.appointment(appointment)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    current_appointment.present? && account_administrator? && feature_enabled?('scheduling') && feature_enabled?('scheduling_finance')
  end

  private

  def appointment_operations
    Captain::Tools::Operations::AppointmentOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end
end
