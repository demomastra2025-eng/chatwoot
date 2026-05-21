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

    def build(account: nil)
      raise ArgumentError, "#{id} requires account" if requires_account && account.blank?

      if requires_account
        suite_class.constantize.new(account: account)
      else
        suite_class.constantize.new
      end
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
