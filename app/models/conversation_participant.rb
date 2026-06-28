# == Schema Information
#
# Table name: conversation_participants
#
#  id              :bigint           not null, primary key
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  conversation_id :bigint           not null
#  user_id         :bigint           not null
#
# Indexes
#
#  index_conversation_participants_on_account_id                   (account_id)
#  index_conversation_participants_on_conversation_id              (conversation_id)
#  index_conversation_participants_on_user_id                      (user_id)
#  index_conversation_participants_on_user_id_and_conversation_id  (user_id,conversation_id) UNIQUE
#
class ConversationParticipant < ApplicationRecord
  validates :account_id, presence: true
  validates :conversation_id, presence: true
  validates :user_id, presence: true
  validates :user_id, uniqueness: { scope: [:conversation_id] }
  validate :ensure_inbox_access

  belongs_to :account
  belongs_to :conversation
  belongs_to :user

  before_validation :ensure_account_id

  def self.find_or_create_for!(conversation:, user_id:)
    participant_scope = conversation.conversation_participants
    participant_scope.find_by(user_id: user_id) || create_for_scope!(participant_scope, user_id)
  end

  def self.create_for_scope!(participant_scope, user_id)
    transaction(requires_new: true) { participant_scope.create!(user_id: user_id) }
  rescue ActiveRecord::RecordNotUnique
    participant_scope.find_by!(user_id: user_id)
  rescue ActiveRecord::RecordInvalid => e
    existing_record = participant_scope.find_by(user_id: user_id)
    return existing_record if existing_record.present? && duplicate_user_error?(e)

    raise
  end

  def self.duplicate_user_error?(error)
    error.record.is_a?(ConversationParticipant) && error.record.errors.of_kind?(:user_id, :taken)
  end
  private_class_method :create_for_scope!, :duplicate_user_error?

  private

  def ensure_account_id
    self.account_id = conversation&.account_id
  end

  def ensure_inbox_access
    errors.add(:user, 'must have inbox access') if conversation && conversation.inbox.assignable_agents.exclude?(user)
  end
end
