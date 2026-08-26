# == Schema Information
#
# Table name: copilot_messages
#
#  id                :bigint           not null, primary key
#  message           :jsonb            not null
#  message_type      :integer          default("user")
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#  copilot_thread_id :bigint           not null
#
# Indexes
#
#  index_copilot_messages_on_account_id         (account_id)
#  index_copilot_messages_on_copilot_thread_id  (copilot_thread_id)
#
class CopilotMessage < ApplicationRecord
  belongs_to :copilot_thread
  belongs_to :account

  enum message_type: { user: 0, assistant: 1, assistant_thinking: 2 }

  validates :message_type, presence: true
  validates :message, presence: true
  before_validation :ensure_account
  validate :validate_message_attributes

  private

  def ensure_account
    self.account_id = copilot_thread&.account_id
  end

  def validate_message_attributes
    return if message.blank?

    allowed_keys = %w[content reasoning function_name tool_call_id status input output reply_suggestion agent_name tool_calls usage
                      captain_trace thinking ui_actions confirmation_gate]
    invalid_keys = message.keys - allowed_keys

    errors.add(:message, "contains invalid attributes: #{invalid_keys.join(', ')}") if invalid_keys.any?
  end
end
