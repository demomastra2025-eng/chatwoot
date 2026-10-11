# frozen_string_literal: true

class Captain::Conversation::AgentOwnership
  def initialize(conversation:, assistant: nil)
    @conversation = conversation
    @assistant = assistant
  end

  def current?(expected_entry_id: nil, expected_revision: nil, enforce_revision: false)
    return false unless entry && assistant && assistant.account_id == conversation.account_id
    return false unless expected_entry_id.blank? || expected_entry_id.to_i == entry.id
    return false unless Captain::AgentGraph.new(entry).find(assistant.id)
    return false unless current_actor_id == assistant.id
    return true unless enforce_revision

    # An old unstamped chain is valid only before the first agent transfer.
    expected_revision.nil? ? routing_revision.zero? : expected_revision.to_i == routing_revision
  end

  def entry
    return @entry if instance_variable_defined?(:@entry)

    conversation.reload
    @entry = conversation.inbox&.captain_assistant
  end

  def current_actor_id
    session['current_assistant_id'].presence&.to_i || entry&.id
  end

  def current_assistant
    return unless entry && entry.account_id == conversation.account_id

    Captain::AgentGraph.new(entry).find(current_actor_id)
  end

  def routing_revision
    session['routing_revision'].to_i
  end

  private

  attr_reader :conversation, :assistant

  def session
    return @session if instance_variable_defined?(:@session)
    return @session = {} unless entry

    @session = Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).read
  end
end
