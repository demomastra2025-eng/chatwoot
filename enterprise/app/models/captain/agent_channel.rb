# frozen_string_literal: true

class Captain::AgentChannel < ApplicationRecord
  self.table_name = 'captain_agent_channels'

  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant'
  belongs_to :inbox

  validates :assistant_id, uniqueness: { scope: :inbox_id }
  validate :same_account_and_text_inbox

  private

  def same_account_and_text_inbox
    return if assistant&.account_id == account_id && assistant.external_agent? &&
              inbox&.account_id == account_id && inbox.channel_type != 'Channel::Voice'

    errors.add(:base, I18n.t('captain.channel_matrix.invalid_channel'))
  end
end
