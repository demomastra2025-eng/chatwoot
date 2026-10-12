# The answer of an agent tool that changed an appointment which may be linked to MedElement. A change that started a
# MedElement command is a write to MedElement, so the tool answers only after MedElement answered it: OK is a success
# (final, a later read never undoes it), a taken slot is a business failure the agent can act on, and anything else
# (rejection, failure, unknown result, no answer in time) is a technical failure that carries the appointment as the
# calendar shows it. Nothing here touches the conversation: the runtime decides what a technical failure means for it.
module Captain::Tools::Agent::ProviderWriteOutput
  private

  def provider_write_output(appointment, action:, operation:)
    command = appointment&.medelement_provider_command_receipt
    return JSON.generate(Captain::Tools::Agent::AppointmentResult.success(appointment, action: action)) unless command&.operation == operation

    begin
      Captain::Tools::ProviderWriteWait.new(command: command).perform
    rescue Scheduling::Error => e
      return unconfirmed_provider_write_output(appointment, action, e)
    end
    JSON.generate(Captain::Tools::Agent::AppointmentResult.success(appointment.reload, action: action))
  end

  def unconfirmed_provider_write_output(appointment, action, error)
    return Captain::Tools::Agent::AppointmentResult.failure_output(error) if business_provider_failure?(error)

    JSON.generate(Captain::Tools::Agent::AppointmentResult.provider_failure(appointment.reload, action: action))
  end

  def business_provider_failure?(error)
    error.code.in?(Captain::Tools::ProviderWriteWait::BUSINESS_FAILURES.values)
  end
end
