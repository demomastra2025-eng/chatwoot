# frozen_string_literal: true

# The AI as a whole, shown as the one who is typing when no agent holds the conversation. A channel has no agent of its own, so the
# typing indicator names none; staff see «AI». It is a payload for the typing events only, not a record.
class Captain::AiActor
  NAME = 'AI'
  TYPE = 'captain_assistant'

  def self.instance
    @instance ||= new
  end

  def id = 0

  def name = NAME

  def push_event_data
    { id: id, name: NAME, type: TYPE }
  end

  def webhook_data
    push_event_data
  end
end
