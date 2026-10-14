# frozen_string_literal: true

module Concerns::CaptainAgentRouting
  extend ActiveSupport::Concern

  ROUTING_DESCRIPTION_MAX_LENGTH = 2000

  included do
    belongs_to :legacy_scenario, class_name: 'Captain::Scenario', optional: true
    has_many :outgoing_agent_handoffs, class_name: 'Captain::AgentHandoff', foreign_key: :source_assistant_id,
                                       inverse_of: :source_assistant, dependent: :delete_all
    has_many :incoming_agent_handoffs, class_name: 'Captain::AgentHandoff', foreign_key: :target_assistant_id,
                                       inverse_of: :target_assistant, dependent: :delete_all
    has_many :handoff_agents, through: :outgoing_agent_handoffs, source: :target_assistant

    scope :entry_eligible, -> { where(active: true, usage_mode: 'external_agent') }

    validates :active, inclusion: { in: [true, false] }
    validates :routing_description, length: { maximum: ROUTING_DESCRIPTION_MAX_LENGTH }, allow_nil: true
    validate :validate_handoff_agent_ids
    after_save :save_handoff_agent_ids!
  end

  def entry_eligible?
    active? && external_agent?
  end

  # The agents this agent can transfer to or consult come from the channel grid:
  # every other active agent attached to a channel where this agent works.
  # Nothing is stored per agent, and the legacy handoff_targets below restrict
  # nothing at runtime (see Captain::AgentGraph for the graph of one channel).
  def channel_peers
    return [] unless entry_eligible?

    Captain::Assistant.entry_eligible.where(account_id: account_id).where.not(id: id).order(:id).to_a
  end

  # Legacy per-agent allowed-targets list. The data is kept, but routing, the
  # prompt and the council ignore it.
  def handoff_targets
    handoff_agents.entry_eligible.where(account_id: account_id).order(:id)
  end

  def handoff_agent_ids
    return normalized_handoff_agent_ids if instance_variable_defined?(:@handoff_agent_ids_input)
    return [] unless persisted?

    outgoing_agent_handoffs.pluck(:target_assistant_id).sort
  end

  # Stage the graph until save so an invalid global settings save changes nothing.
  def handoff_agent_ids=(value)
    @handoff_agent_ids_input = value
  end

  private

  def selected_inbox_ids_by_agent(agents)
    Captain::AgentChannel.where(assistant_id: agents.map(&:id)).pluck(:assistant_id, :inbox_id)
                         .group_by(&:first).transform_values { |rows| rows.map(&:last) }
  end

  # A selected agent works in its listed channels only; an agent of all channels
  # works in every channel, so it meets any agent that works in at least one.
  def shares_channel?(first, second, inbox_ids)
    mine = channels_of(first, inbox_ids)
    theirs = channels_of(second, inbox_ids)
    return true if mine == :all && theirs == :all
    return mine.any? if theirs == :all
    return theirs.any? if mine == :all

    mine.intersect?(theirs)
  end

  def channels_of(agent, inbox_ids)
    agent.channel_scope == 'all' ? :all : inbox_ids.fetch(agent.id, [])
  end

  def normalized_handoff_agent_ids
    Array(@handoff_agent_ids_input).map { |value| value.to_s.to_i }.uniq.sort
  end

  def validate_handoff_agent_ids
    return unless instance_variable_defined?(:@handoff_agent_ids_input)

    input = @handoff_agent_ids_input
    unless input.is_a?(Array) && input.all? { |value| value.to_s.match?(/\A[1-9]\d*\z/) }
      errors.add(:handoff_agent_ids, 'must be an array of agent IDs')
      return
    end

    ids = normalized_handoff_agent_ids
    errors.add(:handoff_agent_ids, 'cannot include this agent') if id.present? && ids.include?(id)
    targets = Captain::Assistant.where(account_id: account_id, id: ids).to_a
    errors.add(:handoff_agent_ids, 'must belong to this workspace') if targets.map(&:id).sort != ids

    existing_ids = persisted? ? outgoing_agent_handoffs.pluck(:target_assistant_id) : []
    return if targets.all? { |target| target.entry_eligible? || existing_ids.include?(target.id) }

    errors.add(:handoff_agent_ids, 'new targets must be active external agents')
  end

  def save_handoff_agent_ids!
    return unless instance_variable_defined?(:@handoff_agent_ids_input)

    desired_ids = normalized_handoff_agent_ids
    outgoing_agent_handoffs.where.not(target_assistant_id: desired_ids).delete_all
    existing_ids = outgoing_agent_handoffs.pluck(:target_assistant_id)
    (desired_ids - existing_ids).each do |target_id|
      outgoing_agent_handoffs.create!(account_id: account_id, target_assistant_id: target_id)
    end
    remove_instance_variable(:@handoff_agent_ids_input)
    association(:outgoing_agent_handoffs).reset
    association(:handoff_agents).reset
  end
end
