# == Schema Information
#
# Table name: communication_thread_conversations
#
#  id                      :bigint           not null, primary key
#  primary                 :boolean          default(FALSE), not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :bigint           not null
#  communication_thread_id :bigint           not null
#  contact_inbox_id        :bigint
#  conversation_id         :bigint           not null
#  inbox_id                :bigint           not null
#
# Indexes
#
#  idx_ctc_account_conversation_unique                           (account_id,conversation_id) UNIQUE
#  idx_ctc_on_thread_id                                          (communication_thread_id)
#  idx_ctc_thread_inbox                                          (communication_thread_id,inbox_id)
#  index_communication_thread_conversations_on_account_id        (account_id)
#  index_communication_thread_conversations_on_contact_inbox_id  (contact_inbox_id)
#  index_communication_thread_conversations_on_conversation_id   (conversation_id)
#  index_communication_thread_conversations_on_inbox_id          (inbox_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (communication_thread_id => communication_threads.id)
#  fk_rails_...  (contact_inbox_id => contact_inboxes.id)
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#
class CommunicationThreadConversation < ApplicationRecord
  belongs_to :account
  belongs_to :communication_thread
  belongs_to :conversation
  belongs_to :inbox
  belongs_to :contact_inbox, optional: true

  validates :account_id, presence: true
  validates :communication_thread_id, presence: true
  validates :conversation_id, presence: true, uniqueness: { scope: :account_id }
  validates :inbox_id, presence: true
  validate :records_belong_to_same_account
  validate :conversation_belongs_to_thread_contact
  validate :channel_fields_match_conversation

  private

  def records_belong_to_same_account
    validate_account_match(:communication_thread, communication_thread&.account_id)
    validate_account_match(:conversation, conversation&.account_id)
    validate_account_match(:inbox, inbox&.account_id)
    validate_account_match(:contact_inbox, contact_inbox&.inbox&.account_id) if contact_inbox.present?
  end

  def conversation_belongs_to_thread_contact
    return if communication_thread.blank? || conversation.blank?
    return if communication_thread.contact_id == conversation.contact_id

    errors.add(:conversation, 'must belong to the same contact as the communication thread')
  end

  def channel_fields_match_conversation
    return if conversation.blank?

    errors.add(:inbox, 'must match the conversation inbox') if inbox_id.present? && inbox_id != conversation.inbox_id
    return if contact_inbox.blank? || contact_inbox_id == conversation.contact_inbox_id

    errors.add(:contact_inbox, 'must match the conversation contact inbox')
  end

  def validate_account_match(attribute, record_account_id)
    return if account_id.blank? || record_account_id.blank? || record_account_id == account_id

    errors.add(attribute, 'must belong to the same account')
  end
end
