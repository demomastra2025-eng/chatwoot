# frozen_string_literal: true

# Which agent holds a conversation. The holder is the agent the router gave the conversation to (the session of the conversation
# names it). Nobody holds a new conversation, or one whose holder was switched off: the router then chooses again. There is no
# default holder.
class Captain::Conversation::AgentOwnership
  def initialize(conversation:, assistant: nil)
    @conversation = conversation
    @assistant = assistant
  end

  # The agent is an enabled agent of the channel and holds the conversation (at the routing revision a run or a follow-up carries).
  def current?(expected_revision: nil, enforce_revision: false)
    return false unless assistant && assistant.account_id == conversation.account_id
    return false unless graph_member(assistant.id)
    return false unless current_actor_id == assistant.id
    return true unless enforce_revision

    # An old unstamped chain is valid only before the first agent transfer.
    expected_revision.nil? ? routing_revision.zero? : expected_revision.to_i == routing_revision
  end

  def current_actor_id
    session['current_assistant_id'].presence&.to_i
  end

  # The holder, or nil when nobody holds the conversation or the holder is no longer an agent of the channel.
  def current_assistant
    graph_member(current_actor_id)
  end

  def routing_revision
    session['routing_revision'].to_i
  end

  private

  attr_reader :conversation, :assistant

  # An agent that is switched off is not a member: nobody is the owner, so the checks answer false/nil instead of raising.
  def graph_member(id)
    return if id.blank?

    Captain::AgentGraph.new(Captain::ChannelScope.for_conversation(conversation)).find(id)
  end

  def session
    @session ||= Captain::Conversation::AgentSession.new(conversation: conversation).read
  end
end
