# frozen_string_literal: true

module Captain::Runtime
  class RunContext
    attr_reader :context, :usage, :callbacks, :callback_manager

    def initialize(context, callbacks: {})
      @context = context
      @usage = Usage.new
      @callbacks = callbacks || {}
      @callback_manager = CallbackManager.new(@callbacks)
    end

    class Usage
      attr_accessor :input_tokens, :output_tokens, :total_tokens

      def initialize
        @input_tokens = 0
        @output_tokens = 0
        @total_tokens = 0
      end

      def add(response)
        return unless response.respond_to?(:input_tokens)

        input = response.input_tokens || 0
        output = response.output_tokens || 0

        @input_tokens += input
        @output_tokens += output
        @total_tokens += input + output
      end
    end
  end
end
