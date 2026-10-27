# frozen_string_literal: true

module Concerns::CaptainAgentRouting
  extend ActiveSupport::Concern

  ROUTING_DESCRIPTION_MAX_LENGTH = 2000

  included do
    belongs_to :legacy_scenario, class_name: 'Captain::Scenario', optional: true

    scope :entry_eligible, -> { where(active: true, usage_mode: 'external_agent') }

    validates :active, inclusion: { in: [true, false] }
    validates :routing_description, length: { maximum: ROUTING_DESCRIPTION_MAX_LENGTH }, allow_nil: true
  end

  # An enabled agent that talks to patients. Every such agent of a workspace is a peer: the router picks among them, and each one has
  # the same switch (`active`). There is no main or default agent.
  def entry_eligible?
    active? && external_agent?
  end
end
