# frozen_string_literal: true

module Captain::ToolResultOutput
  private

  def tool_failure(error, retryable: nil)
    Captain::ToolResult.failure_output(error: error, retryable: retryable)
  end

  def tool_success(message: nil, data: nil)
    Captain::ToolResult.success_output(message: message, data: data)
  end
end
