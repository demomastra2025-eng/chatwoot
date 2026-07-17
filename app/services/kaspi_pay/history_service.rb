class KaspiPay::HistoryService
  def initialize(hook:, client: nil)
    @hook = hook
    @client = client || KaspiPay::Client.new(hook: hook)
  end

  def operations(end_date:, last_transaction_date: nil, statement_period_code: 0)
    normalize(client.operations_history(
                end_date: end_date,
                last_transaction_date: last_transaction_date,
                statement_period_code: statement_period_code
              ))
  end

  def operation_details(id:, operation_method: 0)
    normalize(client.operation_details(id, operation_method: operation_method))
  end

  def invoice_history
    normalize(client.invoice_history)
  end

  private

  attr_reader :client, :hook

  def normalize(response)
    if response['StatusCode'].present? && response['StatusCode'].to_i != 0
      raise KaspiPay::Error.new('Kaspi Pay history request failed', details: response)
    end

    response['Data'] || response['data'] || response
  end
end
