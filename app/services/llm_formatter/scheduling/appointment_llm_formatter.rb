module LlmFormatter::Scheduling
  class AppointmentLlmFormatter < LlmFormatter::DefaultLlmFormatter
    def format(*)
      sections = []
      sections << "Appointment ID: ##{@record.id}"
      sections << "Status: #{@record.status}"
      sections << "Appointment Type: #{@record.appointment_type}"
      sections << "Starts At: #{@record.starts_at}"
      sections << "Ends At: #{@record.ends_at}"
      sections << "Client Name: #{@record.client_name}"
      sections << "Client Phone: #{@record.client_phone.presence || 'Not set'}"
      sections << "Specialist: #{@record.resource&.name || 'Not set'}"
      sections << "Service: #{@record.service_name_snapshot.presence || @record.service&.name || 'Not set'}"
      sections << "Payment Status: #{@record.payment_status}"
      sections << "Service Amount: #{@record.service_amount}"
      sections << "Company: #{@record.company&.name || 'Not set'}"
      sections << "Custom Attributes: #{@record.custom_attributes.to_json}"
      sections.join("\n")
    end
  end
end
