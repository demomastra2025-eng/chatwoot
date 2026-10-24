# The answer of Scheduling::AvailabilityService#availability_result: whether the time is free and, when it is not, the code and the
# message of the reason (and its details, such as the starts next to a start that is off the grid).
Scheduling::AvailabilityResult = Struct.new(:available, :code, :message, :details, keyword_init: true) do
  def available?
    available
  end

  # The HTTP status of a refusal: 422 for a wrong request (an end before the start, a start that is not on the grid of the
  # specialist), 409 for a time that is not free.
  def status
    code.in?(%w[VALIDATION_ERROR START_OFF_GRID]) ? :unprocessable_content : :conflict
  end
end
