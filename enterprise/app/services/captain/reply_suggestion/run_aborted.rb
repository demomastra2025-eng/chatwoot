# frozen_string_literal: true

# Raised at a checkpoint when the manager cancelled the run (:cancelled) or the budget is spent (:deadline).
#
# It is a ControlGenerationStaleError on purpose: the runtime already re-raises that class at every layer (Runner#run,
# ToolWrapper#call, AgentRunnerService#generate_response), so an abort can never be turned into a result by a
# `rescue StandardError` on the way up.
class Captain::ReplySuggestion::RunAborted < Captain::Conversation::ControlGenerationStaleError
  KINDS = %i[cancelled deadline].freeze

  attr_reader :kind, :stage

  def initialize(kind, stage)
    @kind = kind.to_sym
    @stage = stage.to_s
    super("Reply suggestion run #{@kind} at #{@stage}")
  end
end
