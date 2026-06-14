# frozen_string_literal: true

class Llm::OpenRouterParameterCapabilities
  PARAMETER_CAPABILITIES = {
    'tools' => ['tool_calling'],
    'tool_choice' => %w[tool_calling tool_choice],
    'response_format' => ['structured_output'],
    'structured_outputs' => ['structured_output'],
    'reasoning' => ['reasoning'],
    'reasoning_effort' => ['reasoning'],
    'include_reasoning' => ['reasoning'],
    'parallel_tool_calls' => ['parallel_tool_calls']
  }.freeze

  class << self
    def derive(capabilities:, supported_parameters:)
      (Array(capabilities).map(&:to_s) + from_parameters(supported_parameters)).compact_blank.uniq
    end

    def from_parameters(supported_parameters)
      Array(supported_parameters).map(&:to_s).flat_map do |parameter|
        PARAMETER_CAPABILITIES[parameter]
      end.compact
    end
  end
end
