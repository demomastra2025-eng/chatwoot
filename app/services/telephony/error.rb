class Telephony::Error < StandardError
  attr_reader :code, :details, :status

  def initialize(code:, message:, status: :unprocessable_content, details: nil)
    @code = code
    @details = details
    @status = status
    super(message)
  end
end
