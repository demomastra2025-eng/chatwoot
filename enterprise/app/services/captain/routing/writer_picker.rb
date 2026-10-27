# frozen_string_literal: true

# Picks the agent that writes a message nobody is answering right now: the text of a campaign or of a touch that staff set up with
# an AI text. The router (Captain::Runtime::DecisionRouter) decides from the instruction, exactly as it does for a patient message,
# and the chosen agent is stored with the campaign or the touch. A workspace with one enabled agent makes no decision. nil when no
# agent can be chosen (every agent is off, several are on and none has a card, or the router found none); nothing stands in for it.
class Captain::Routing::WriterPicker
  def self.pick(account:, instruction:, source:)
    new(account: account, instruction: instruction, source: source).pick
  end

  def initialize(account:, instruction:, source:)
    @account = account
    @instruction = instruction.to_s.squish
    @source = source
  end

  def pick
    graph = Captain::AgentGraph.new(Captain::ChannelScope.for_workspace(@account))
    return graph.candidates.first if graph.solo?
    return if @instruction.blank?

    decision = router(graph).redecide(fragment: @instruction, without: [])
    graph.find(decision.agent_id) if decision&.agent?
  rescue Captain::Runtime::DecisionRouter::UnavailableError => e
    Rails.logger.warn("[CAPTAIN][Router] no writer picked source=#{@source} reason=#{e.reason}")
    nil
  end

  private

  def router(graph)
    snapshot = Captain::Runtime::RoutingSnapshot.new(
      agents: Captain::Runtime::RoutingSnapshot.agents_for(graph.candidate_rows), latest_message: @instruction,
      clinic: @account.name, human_available: false, source: @source
    )
    Captain::Runtime::DecisionRouter.new(snapshot, account: @account, observability: { account_id: @account.id, source: @source })
  end
end
