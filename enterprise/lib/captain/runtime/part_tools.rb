# frozen_string_literal: true

# The tools of one council part. A part is a normal run of the agent that owns it, so it gets that agent's own tools exactly as
# in a conversation with the customer, mutating tools included (booking, moving and cancelling are done by the owner itself).
# Only the three tools that change who controls the conversation are withheld: they write a pending handoff, resolution or
# cancellation into the part's own context, which nothing reads, so a part text would say "passed to staff" while nothing
# happens (and the halt would end the run). A human handoff after a council is structural (see Council#council_handoff).
# Classes are compared, not names, so a renamed or prefixed tool is still recognised.
class Captain::Runtime::PartTools
  WITHHELD = [
    Captain::Tools::HandoffTool, Captain::Tools::ResolveConversationTool, Captain::Tools::CancelResponseTool
  ].freeze

  class << self
    def allowed?(tool)
      WITHHELD.none? { |kind| tool.is_a?(kind) }
    end

    def filter(tools)
      Array(tools).select { |tool| allowed?(tool) }
    end

    def read_only_allowed?(tool)
      allowed?(tool) && !Llm::ToolRiskPolicy.mutating?(tool)
    end

    def filter_read_only(tools)
      Array(tools).select { |tool| read_only_allowed?(tool) }
    end

    # The registry ids of the withheld tools. The prompt of a part is written before its tools are built: it must not tell the owner to
    # hand the conversation over, nor name a tool that the part does not get.
    def withheld_tool_ids
      Captain::ToolRegistry.definitions.select { |definition| WITHHELD.include?(definition.agent_tool_class) }.map(&:id)
    end

    def read_only_withheld_tool_ids
      Captain::ToolRegistry.definitions.select do |definition|
        WITHHELD.include?(definition.agent_tool_class) ||
          Llm::ToolRiskPolicy::MUTATING_RISK_LEVELS.include?(definition.risk_level.to_s)
      end.map(&:id)
    end
  end
end
