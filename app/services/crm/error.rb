class Crm::Error < StandardError
  attr_reader :code, :status, :details

  def initialize(code:, message:, status:, details: nil)
    super(message)
    @code = code
    @status = status
    @details = details
  end
end
