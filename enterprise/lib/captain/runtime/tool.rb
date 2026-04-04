# frozen_string_literal: true

class Captain::Runtime::Tool < RubyLLM::Tool
  def execute(tool_context, **params)
    perform(tool_context, **params)
  end

  def perform(tool_context, **params)
    raise NotImplementedError, "#{self.class.name} must implement #perform(tool_context, **params)"
  end
end
