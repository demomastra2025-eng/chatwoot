# frozen_string_literal: true

class Llm::MessageTokenPayload
  class << self
    def for(response)
      input = token_value(response, :input_tokens)
      output = token_value(response, :output_tokens)
      thinking = token_value(response, :thinking_tokens) || token_value(response, :reasoning_tokens)

      {
        prompt_tokens: input,
        completion_tokens: output,
        thinking_tokens: thinking,
        total_tokens: total_tokens(input, output)
      }.compact
    end

    private

    def token_value(response, method_name)
      return unless response.respond_to?(method_name)

      value = response.public_send(method_name)
      return if value.blank?

      value.to_i
    rescue StandardError
      nil
    end

    def total_tokens(input, output)
      return if input.nil? && output.nil?

      input.to_i + output.to_i
    end
  end
end
