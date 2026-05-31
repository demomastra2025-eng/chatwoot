# frozen_string_literal: true

class Llm::Evals::Scenario::AgentAdapter
  ROLES = %w[user agent judge observer].freeze

  Input = Struct.new(
    :thread_id,
    :messages,
    :new_messages,
    :state,
    :fixtures,
    :account,
    :trace_events,
    keyword_init: true
  )

  Output = Struct.new(
    :messages,
    :events,
    :verdict,
    :reasoning,
    keyword_init: true
  )

  attr_reader :role, :name

  def initialize(role:, name: nil)
    normalized_role = role.to_s
    raise ArgumentError, "unsupported scenario agent role: #{role}" unless ROLES.include?(normalized_role)

    @role = normalized_role
    @name = name.to_s.presence || self.class.name
  end

  def call(_input)
    raise NotImplementedError, "#{self.class.name} must implement #call"
  end
end
