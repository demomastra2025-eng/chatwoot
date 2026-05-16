class Captain::Tools::Copilot::SearchKaspiPayPaymentsService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'search_kaspi_pay_payments'
  end

  description 'Admin-only: search Kaspi Pay payments within the current account by status, source, date, or source record'
  param :status, type: :string, desc: 'Optional payment status: pending, paid, expired, failed, cancelled, or refunded', required: false
  param :source_type, type: :string, desc: 'Optional source type: Conversation or Scheduling::Appointment', required: false
  param :conversation_id, type: :number, desc: 'Optional conversation display ID', required: false
  param :appointment_id, type: :number, desc: 'Optional appointment database ID', required: false
  param :from, type: :string, desc: 'Optional created_at lower bound in ISO 8601 format', required: false
  param :to, type: :string, desc: 'Optional created_at upper bound in ISO 8601 format', required: false
  param :limit, type: :number, desc: 'Maximum number of payments to return, capped at 50', required: false

  def execute(status: nil, source_type: nil, conversation_id: nil, appointment_id: nil, from: nil, to: nil, limit: nil)
    formatted_kaspi_payload(
      kaspi_pay_operations.search_payments(
        status: status,
        source_type: source_type,
        conversation_id: conversation_id,
        appointment_id: appointment_id,
        from: from,
        to: to,
        limit: limit
      )
    )
  end
end
