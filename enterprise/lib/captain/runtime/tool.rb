# frozen_string_literal: true

class Captain::Runtime::Tool < RubyLLM::Tool
  def execute(tool_context, **params)
    state = tool_context&.state
    if is_a?(Captain::Tools::HttpTool) || is_a?(Captain::Runtime::HandoffTool) ||
       (state.is_a?(Hash) && state.keys.map(&:to_s).intersect?(%w[assistant_id account_id conversation]))
      Captain::CustomerToolExecutionScope.ensure_allowed!(tool: self, state: state, params: params)
    end
    perform(tool_context, **params)
  end

  def perform(tool_context, **params)
    raise NotImplementedError, "#{self.class.name} must implement #perform(tool_context, **params)"
  end
end
