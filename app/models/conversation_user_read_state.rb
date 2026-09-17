# == Schema Information
#
# Table name: conversation_user_read_states
#
#  id              :bigint           not null, primary key
#  last_seen_at    :datetime
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  conversation_id :bigint           not null
#  user_id         :bigint           not null
#
class ConversationUserReadState < ApplicationRecord
  belongs_to :account
  belongs_to :conversation
  belongs_to :user

  validates :conversation_id, uniqueness: { scope: :user_id }
  validate :account_matches_conversation

  private

  def account_matches_conversation
    return if account_id.blank? || conversation.blank? || account_id == conversation.account_id

    errors.add(:account_id, 'must match conversation account')
  end
end
