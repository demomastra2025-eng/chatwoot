# frozen_string_literal: true

class Captain::AgentHandoff < ApplicationRecord
  self.table_name = 'captain_agent_handoffs'

  belongs_to :account
  belongs_to :source_assistant, class_name: 'Captain::Assistant', inverse_of: :outgoing_agent_handoffs
  belongs_to :target_assistant, class_name: 'Captain::Assistant', inverse_of: :incoming_agent_handoffs

  validates :target_assistant_id, uniqueness: { scope: :source_assistant_id }
  validate :assistants_belong_to_account
  validate :different_assistants
  validate :new_target_is_eligible, on: :create

  private

  def assistants_belong_to_account
    return if source_assistant&.account_id == account_id && target_assistant&.account_id == account_id

    errors.add(:account, 'must match both agents')
  end

  def different_assistants
    return unless source_assistant_id.present? && source_assistant_id == target_assistant_id

    errors.add(:target_assistant, 'must be a different agent')
  end

  def new_target_is_eligible
    return if target_assistant&.entry_eligible?

    errors.add(:target_assistant, 'must be an active external agent')
  end
end
