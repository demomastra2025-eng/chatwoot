# frozen_string_literal: true

module Captain::Runtime
  Result = Struct.new(:output, :messages, :usage, :error, :context, keyword_init: true) do
    def success?
      error.nil? && !output.nil?
    end

    def failed?
      !success?
    end
  end
end
