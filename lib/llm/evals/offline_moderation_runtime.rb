# frozen_string_literal: true

module Llm
  module Evals
    module OfflineModerationRuntime
      ModerationProbe = Struct.new(:flagged?)
      ModerationResponse = Struct.new(:content)

      private

      def with_provider_mode(mode, &)
        case mode.to_s.presence || 'allowed'
        when 'unavailable'
          stubbed_runtime(api_key: nil, &)
        when 'flagged'
          stubbed_runtime(api_key: 'eval-key', moderation_probe: ModerationProbe.new(true), &)
        else
          stubbed_runtime(api_key: 'eval-key', moderation_probe: ModerationProbe.new(false), &)
        end
      end

      def stubbed_runtime(api_key:, moderation_probe: nil, &)
        stubs = [
          { target: Llm::Config, method: :api_key, callable: ->(*) { api_key } },
          { target: Llm::Config, method: :moderation_model, callable: ->(*) { 'omni-moderation-latest' } }
        ]
        stubs.concat(openrouter_moderation_stubs(moderation_probe)) if moderation_probe

        Llm::Evals::MethodStub.with_many(stubs, &)
      end

      def openrouter_moderation_stubs(moderation_probe)
        payload = offline_moderation_payload(moderation_probe)
        [
          { target: Llm::Models, method: :supports_structured_output?, callable: ->(*, **) { true } },
          { target: Llm::Runtime, method: :build_chat, callable: ->(*, **) { Object.new } },
          { target: Llm::StructuredOutputPolicy, method: :bind!, callable: ->(chat:, schema:) { chat } },
          { target: Llm::Runtime, method: :ask, callable: ->(*, **) { ModerationResponse.new(payload.deep_dup) } }
        ]
      end

      def offline_moderation_payload(moderation_probe)
        {
          flagged: moderation_probe.flagged?,
          categories: moderation_probe.flagged? ? ['policy_violation'] : [],
          reason: moderation_probe.flagged? ? 'policy_violation' : ''
        }
      end
    end
  end
end
