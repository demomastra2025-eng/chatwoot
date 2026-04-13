# frozen_string_literal: true

module Llm
  module Evals
    module OfflineModerationRuntime
      ModerationProbe = Struct.new(:flagged?)

      private

      def with_provider_mode(mode, &block)
        case mode.to_s.presence || 'allowed'
        when 'unavailable'
          stubbed_runtime(api_key: nil, &block)
        when 'flagged'
          stubbed_runtime(api_key: 'eval-key', moderation_probe: ModerationProbe.new(true), &block)
        else
          stubbed_runtime(api_key: 'eval-key', moderation_probe: ModerationProbe.new(false), &block)
        end
      end

      def stubbed_runtime(api_key:, moderation_probe: nil, &block)
        stubs = [
          { target: Llm::Config, method: :api_key, callable: ->(*) { api_key } },
          { target: Llm::Config, method: :moderation_model, callable: ->(*) { 'omni-moderation-latest' } }
        ]
        stubs << { target: Llm::ApiClient, method: :moderate, callable: ->(*, **) { moderation_probe } } if moderation_probe

        Llm::Evals::MethodStub.with_many(stubs, &block)
      end
    end
  end
end
