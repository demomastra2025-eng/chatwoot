class Integrations::Medelement::ProviderCommands::ConfirmationBodyBuilder
  def initialize(operation:, snapshot:)
    @operation = operation
    @snapshot = snapshot
  end

  def build
    return patient_body if reception.blank?

    reception_body
  end

  private

  attr_reader :operation, :snapshot

  def reception_body
    details = snapshot.fetch('confirmation', {})
    [
      "Операция #{operation} для записи ##{snapshot['appointment_id']}",
      "пациент #{details['patient_name']}",
      "специалист #{details['specialist_name']} (#{reception['specialist_code']})",
      "услуга #{details['service_name']}",
      "цена #{details['price']}",
      "длительность #{details['duration_min']} мин",
      time_body,
      "кабинет #{snapshot['company_cabinet_code']}",
      patient_resolution_notice
    ].compact.join('; ')
  end

  def patient_resolution_notice
    return unless operation == 'create_reception' && snapshot['provider_patient_code'].blank?

    'если пациент не будет однозначно найден по данным записи, будет создан новый пациент Medelement; локальный контакт не создаётся'
  end

  def time_body
    destination = "#{reception['destination_starts_at']} — #{reception['destination_ends_at']}"
    return "время #{destination}" unless operation == 'move_reception'

    source = "#{reception['source_starts_at']} — #{reception['source_ends_at']}"
    "исходное время #{source}; новое время #{destination}"
  end

  def patient_body
    phone_number = snapshot.dig('patient', 'phone_number')
    "Операция #{operation} для контакта ##{snapshot['contact_id']}; телефон #{phone_number}"
  end

  def reception
    @reception ||= snapshot['reception']
  end
end
