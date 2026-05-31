# frozen_string_literal: true

class Llm::Evals::Scenario::State
  include Llm::Evals::Scenario::StateTextHelpers
  include Llm::Evals::Scenario::StateToolQueries
  include Llm::Evals::Scenario::StateQueries

  attr_reader :thread_id, :events, :terminal_status, :terminal_reason

  def initialize(thread_id: SecureRandom.uuid)
    @thread_id = thread_id
    @events = []
    @terminal_status = nil
    @terminal_reason = nil
  end

  def add_user(payload)
    add_message('user', payload)
  end

  def add_assistant(payload)
    add_message('assistant', payload)
  end

  def add_message(role, payload)
    attributes = normalize_payload(payload).merge(role: role.to_s)
    attributes[:action] ||= "#{role}_message"
    attributes[:content] = attributes[:content].to_s if attributes.key?(:content)
    add_event(attributes)
  end

  def add_tool_event(action, payload)
    attributes = normalize_payload(payload)
    attributes[:action] = action.to_s
    attributes[:tool_name] = (attributes[:tool_name] || attributes[:name]).to_s.presence
    add_event(attributes)
  end

  def add_event(payload)
    attributes = normalize_payload(payload)
    attributes[:_index] = @events.size
    @events << attributes
    attributes
  end

  def succeed!(reason = nil)
    @terminal_status = 'pass'
    @terminal_reason = reason.to_s.presence
  end

  def fail!(reason = nil)
    @terminal_status = 'fail'
    @terminal_reason = reason.to_s.presence
  end

  def terminal?
    @terminal_status.present?
  end
end
