class Reminders::RetryableExecutionError < StandardError
  attr_reader :preserve_claim

  def initialize(message = nil, preserve_claim: false)
    super(message)
    @preserve_claim = preserve_claim
  end
end
