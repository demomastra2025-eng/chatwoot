class Integrations::Medelement::ProviderCommands::SuccessApplier
  def initialize(command:)
    @command = command
  end

  def patient!(patient_code:)
    ApplicationRecord.transaction do
      touch_contact_sync!
      complete_command!(provider_patient_code: patient_code)
    end
  end

  def reception_created!(reception_code:)
    ApplicationRecord.transaction do
      appointment.update!(
        source: 'medelement',
        external_ref: "medelement:reception:#{reception_code}",
        custom_attributes: appointment.custom_attributes.to_h.merge(
          'medelement_reception_code' => reception_code,
          'medelement_patient_code' => command.provider_patient_code,
          'medelement_cabinet_code' => command.company_cabinet_code,
          'medelement_provider_sync_status' => 'succeeded'
        )
      )
      complete_command!(provider_reception_code: reception_code)
    end
  end

  def reception_moved!
    ApplicationRecord.transaction do
      appointment.update!(
        starts_at: command.desired_starts_at,
        ends_at: command.desired_ends_at,
        custom_attributes: appointment.custom_attributes.to_h.merge(
          'medelement_cabinet_code' => command.company_cabinet_code,
          'medelement_provider_sync_status' => 'succeeded'
        )
      )
      complete_command!
    end
  end

  def reception_removed!
    ApplicationRecord.transaction do
      appointment.update!(
        status: 'cancelled',
        custom_attributes: appointment.custom_attributes.to_h.merge('medelement_provider_sync_status' => 'succeeded')
      )
      complete_command!
    end
  end

  private

  attr_reader :command

  def appointment
    command.appointment
  end

  def touch_contact_sync!
    return if command.contact.blank?

    command.contact.skip_runtime_events = true
    command.contact.update!(
      custom_attributes: command.contact.custom_attributes.to_h.merge('medelement_last_synced_at' => Time.current.iso8601)
    )
  end

  def complete_command!(attributes = {})
    command.update!(
      attributes.merge(
        status: 'succeeded',
        executed_at: Time.current,
        last_error_code: nil,
        last_error_status: nil,
        execution_state: command.execution_state.merge('result' => 'applied')
      )
    )
  end
end
