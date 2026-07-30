class Captain::Tools::Copilot::GetKaspiPayProviderHistoryService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'get_kaspi_pay_provider_history'
  end

  description 'Admin-only: read Kaspi provider operations or remote invoice history for reconciliation'
  param :kind, type: :string, desc: 'History kind: operations or invoices', required: true
  param :end_date, type: :string, desc: 'Operations history end date in YYYY-MM-DD format. Defaults to today.', required: false
  param :last_transaction_date, type: :string, desc: 'Optional operations pagination cursor date in YYYY-MM-DD format.', required: false
  param :statement_period_code, type: :number, desc: 'Kaspi statement period code. Defaults to 0.', required: false

  def execute(kind:, end_date: nil, last_transaction_date: nil, statement_period_code: 0)
    formatted_kaspi_payload(
      kaspi_pay_operations.provider_history(
        kind: kind,
        end_date: end_date,
        last_transaction_date: last_transaction_date,
        statement_period_code: statement_period_code
      )
    )
  end
end
