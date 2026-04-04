# == Schema Information
#
# Table name: copilot_threads
#
#  id           :bigint           not null, primary key
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#  assistant_id :integer
#  user_id      :bigint           not null
#
# Indexes
#
#  index_copilot_threads_on_account_id    (account_id)
#  index_copilot_threads_on_assistant_id  (assistant_id)
#  index_copilot_threads_on_user_id       (user_id)
#
class CopilotThread < ApplicationRecord
  belongs_to :user
  belongs_to :account
  belongs_to :assistant, class_name: 'Captain::Assistant'
  has_many :copilot_messages, dependent: :destroy_async

  validates :title, presence: true

  def push_event_data
    {
      id: id,
      title: title,
      created_at: created_at.to_i,
      user: user.push_event_data,
      account_id: account_id
    }
  end

  def previous_history
    copilot_messages
      .where(message_type: %w[user assistant])
      .order(created_at: :asc)
      .map do |copilot_message|
        message = {
          content: copilot_message.message['content'],
          role: copilot_message.message_type
        }

        message[:agent_name] = copilot_message.message['agent_name'] if copilot_message.message['agent_name'].present?
        message[:tool_calls] = copilot_message.message['tool_calls'] if copilot_message.message['tool_calls'].present?
        message
      end
  end
end
