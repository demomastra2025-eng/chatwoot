# frozen_string_literal: true

module Llm
  module Evals
    class CaseLoader
      def initialize(path:)
        @path = Pathname.new(path)
      end

      def load
        payload = YAML.safe_load(@path.read, aliases: true) || {}
        cases = payload.is_a?(Hash) ? payload.fetch('cases', []) : payload

        Array(cases).map.with_index do |raw_case, index|
          normalize_case(raw_case, index)
        end
      end

      private

      def normalize_case(raw_case, index)
        payload = raw_case.to_h.deep_symbolize_keys
        input = normalize_input(payload.except(:id, :description, :tags, :expected))

        {
          id: payload[:id].presence || "case_#{index + 1}",
          description: payload[:description].to_s.presence,
          tags: Array(payload[:tags]).map(&:to_s),
          input: input,
          expected: payload.fetch(:expected, {}).deep_symbolize_keys
        }.compact
      end

      def normalize_input(payload)
        normalized = payload.deep_symbolize_keys
        normalized[:messages] = normalize_messages(normalized[:messages]) if normalized.key?(:messages)
        normalized
      end

      def normalize_messages(raw_messages)
        Array(raw_messages).filter_map do |raw_message|
          message = raw_message.to_h.deep_symbolize_keys
          content = message[:content].to_s
          next if content.blank?

          {
            role: message[:role].to_s == 'user' ? 'user' : 'assistant',
            content: content
          }
        end
      end
    end
  end
end
