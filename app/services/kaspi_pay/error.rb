class KaspiPay::Error < StandardError
  attr_reader :code, :details, :status

  def initialize(message, code: 'KASPI_PAY_ERROR', status: :unprocessable_content, details: nil)
    @code = code
    @details = details
    @status = Rack::Utils.status_code(status)
    super(message)
  end
end
