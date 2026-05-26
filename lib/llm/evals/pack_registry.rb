# frozen_string_literal: true

class Llm::Evals::PackRegistry
  Pack = Struct.new(
    :id,
    :label,
    :description,
    :suite_class,
    :requires_account,
    :live_model,
    :deterministic,
    :default_enabled,
    keyword_init: true
  ) do
    def to_h
      {
        id: id,
        label: label,
        description: description,
        requires_account: requires_account,
        live_model: live_model,
        deterministic: deterministic,
        default_enabled: default_enabled
      }
    end

    def build(account: nil, max_cases: nil)
      raise ArgumentError, "#{id} requires account" if requires_account && account.blank?

      kwargs = {}
      kwargs[:account] = account if requires_account
      kwargs[:max_cases] = max_cases if live_model && max_cases.present?

      suite_class.constantize.new(**kwargs)
    end
  end

  PACKS = [
    Pack.new(
      id: 'llm.moderation',
      label: 'LLM moderation safety',
      description: 'Offline checks for assistant/copilot moderation failure modes.',
      suite_class: 'Llm::Evals::ModerationSuite',
      requires_account: false,
      live_model: false,
      deterministic: true,
      default_enabled: true
    ),
    Pack.new(
      id: 'captain.tool_safety',
      label: 'Captain tool safety',
      description: 'Offline checks for Captain tool argument/result safety gates.',
      suite_class: 'Captain::Evals::ToolSafetySuite',
      requires_account: false,
      live_model: false,
      deterministic: true,
      default_enabled: true
    ),
    Pack.new(
      id: 'captain.confirmation_safety',
      label: 'Captain confirmation safety',
      description: 'Offline checks that risky assistant tools require confirmation and read-only tools are not over-gated.',
      suite_class: 'Captain::Evals::ConfirmationSafetySuite',
      requires_account: false,
      live_model: false,
      deterministic: true,
      default_enabled: true
    ),
    Pack.new(
      id: 'captain.ai_voice_trace',
      label: 'AI Voice trace integrity',
      description: 'Offline trace checks for clipped speech and unused completed tool results.',
      suite_class: 'Captain::Evals::AiVoiceTraceSuite',
      requires_account: false,
      live_model: false,
      deterministic: true,
      default_enabled: true
    ),
    Pack.new(
      id: 'captain.event_contract_trace',
      label: 'Captain event-contract trace fixtures',
      description: 'Deterministic checks for normalized event names, project case IDs, payload budgets, and raw-content-free traces.',
      suite_class: 'Captain::Evals::EventContractTraceSuite',
      requires_account: false,
      live_model: false,
      deterministic: true,
      default_enabled: true
    ),
    Pack.new(
      id: 'captain.knowledge_rag_trace',
      label: 'Captain Knowledge/RAG trace integrity',
      description: 'Offline checks that Knowledge/RAG success uses semantic chunks and degraded fallbacks stay explicit.',
      suite_class: 'Captain::Evals::KnowledgeRagTraceSuite',
      requires_account: false,
      live_model: false,
      deterministic: true,
      default_enabled: true
    ),
    Pack.new(
      id: 'captain.red_team',
      label: 'Captain red-team attacks',
      description: 'Offline Tribunal red-team prompt generation coverage for Captain safety hardening.',
      suite_class: 'Captain::Evals::RedTeamSuite',
      requires_account: false,
      live_model: false,
      deterministic: true,
      default_enabled: true
    ),
    Pack.new(
      id: 'captain.conversation_completion',
      label: 'Captain conversation completion',
      description: 'Account-scoped live-model regression checks for Captain answer completion.',
      suite_class: 'Captain::Evals::ConversationCompletionSuite',
      requires_account: true,
      live_model: true,
      deterministic: false,
      default_enabled: false
    )
  ].freeze

  class << self
    def catalog
      PACKS.map(&:to_h)
    end

    def default_packs(include_live: false)
      PACKS.select do |pack|
        pack.default_enabled || (include_live && pack.live_model)
      end
    end

    def find!(id)
      PACKS.find { |pack| pack.id == id.to_s } || raise(ArgumentError, "Unknown eval pack: #{id}")
    end
  end
end
