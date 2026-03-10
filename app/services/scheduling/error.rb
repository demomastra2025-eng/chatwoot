class Scheduling::Error < StandardError
  attr_reader :code, :details, :status

  def initialize(code:, message:, status:, details: nil)
    @code = code
    @details = details
    @status = Rack::Utils.status_code(status)
    super(message)
  end
end
