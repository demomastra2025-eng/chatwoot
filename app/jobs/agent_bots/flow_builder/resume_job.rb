class AgentBots::FlowBuilder::ResumeJob < ApplicationJob
  queue_as :default

  def perform(agent_bot_id, conversation_id, node_ids)
    agent_bot = AgentBot.find_by(id: agent_bot_id)
    conversation = Conversation.find_by(id: conversation_id)
    return if agent_bot.blank? || conversation.blank?

    AgentBots::FlowBuilder::RunnerService.new(
      agent_bot: agent_bot,
      conversation: conversation
    ).resume(node_ids: node_ids)
  end
end
