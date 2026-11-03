# frozen_string_literal: true

module Captain::Runtime
  class RunContext
    attr_reader :context, :usage, :callbacks, :callback_manager
    attr_accessor :council_mutation_guard

    def initialize(context, callbacks: {})
      @context = context
      @usage = Usage.new
      @callbacks = callbacks || {}
      @callback_manager = CallbackManager.new(@callbacks)
    end

    def mutating_tool_guard
      @mutating_tool_guard ||= Mutex.new
    end

    def tool_loop_guard_mutex
      @tool_loop_guard_mutex ||= Mutex.new
    end

    # A council shares this guard across its parts, outside the serializable context.
    # The per-model-batch reservation mutex above remains local to each part.
    def with_mutating_tool_execution(&)
      return yield unless council_mutation_guard

      Captain::Runtime::Council::ThreadScope.release_idle_connections!
      council_mutation_guard.synchronize(&)
    ensure
      Captain::Runtime::Council::ThreadScope.release_idle_connections! if council_mutation_guard
    end

    class Usage
      attr_accessor :input_tokens, :output_tokens, :total_tokens, :thinking_tokens

      def initialize
        @input_tokens = 0
        @output_tokens = 0
        @total_tokens = 0
        @thinking_tokens = 0
      end

      def add(response)
        return unless response.respond_to?(:input_tokens)

        input = response.input_tokens || 0
        output = response.output_tokens || 0
        thinking = response.respond_to?(:thinking_tokens) ? response.thinking_tokens.to_i : 0

        @input_tokens += input
        @output_tokens += output
        @total_tokens += input + output
        @thinking_tokens += thinking
      end
    end
  end
end
