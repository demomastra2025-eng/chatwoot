# frozen_string_literal: true

module Captain::Runtime
  class ToolContext
    attr_reader :run_context, :retry_count

    def initialize(run_context:, retry_count: 0)
      @run_context = run_context
      @retry_count = retry_count
    end

    def context
      @run_context.context
    end

    def usage
      @run_context.usage
    end

    def state
      context[:state] ||= {}
    end
  end
end
