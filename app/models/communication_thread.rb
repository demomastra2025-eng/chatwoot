# == Schema Information
#
# Table name: communication_threads
#
#  id               :bigint           not null, primary key
#  last_activity_at :datetime
#  priority         :integer
#  status           :integer          default("open"), not null
#  unread_count     :integer          default(0), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  assignee_id      :bigint
#  contact_id       :bigint           not null
#  display_id       :bigint           not null
#  team_id          :bigint
#
# Indexes
#
#  idx_communication_threads_account_activity        (account_id,last_activity_at)
#  idx_communication_threads_account_contact_status  (account_id,contact_id,status)
#  idx_communication_threads_account_display         (account_id,display_id) UNIQUE
#  index_communication_threads_on_account_id         (account_id)
#  index_communication_threads_on_assignee_id        (assignee_id)
#  index_communication_threads_on_contact_id         (contact_id)
#  index_communication_threads_on_team_id            (team_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (assignee_id => users.id)
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (team_id => teams.id)
#
class CommunicationThread < ApplicationRecord
  enum status: { open: 0, resolved: 1, pending: 2, snoozed: 3 }
  enum priority: { low: 0, medium: 1, high: 2, urgent: 3 }

  belongs_to :account
  belongs_to :contact
  belongs_to :assignee, class_name: 'User', optional: true
  belongs_to :team, optional: true

  has_many :communication_thread_conversations, dependent: :destroy
  has_many :conversations, through: :communication_thread_conversations
  has_many :meta_ad_referrals, dependent: :nullify

  before_validation :ensure_display_id, on: :create

  validates :account_id, presence: true
  validates :contact_id, presence: true
  validates :display_id, presence: true, uniqueness: { scope: :account_id }

  scope :with_labels, lambda { |labels, accessible_conversations: nil|
    with_label_tag_ids(Labels::ConversationScope.tag_ids_for(labels), accessible_conversations: accessible_conversations)
  }
  scope :with_any_label, lambda { |accessible_conversations: nil|
    with_label_tag_ids(nil, accessible_conversations: accessible_conversations)
  }

  # The thread of a person. There is one per person (the resolver keeps it so); where an old duplicate is still there, every reader
  # takes the same one: the one with the latest activity, then the oldest.
  def self.of_person(account_id:, contact_id:)
    where(account_id: account_id, contact_id: contact_id).order(Arel.sql('last_activity_at DESC NULLS LAST'), id: :asc).first
  end

  # Earliest wake-up time among the snoozed channels of a person. Channels snoozed "until the next reply" have no time.
  def self.snoozed_until_for(conversations)
    Array(conversations).filter_map { |conversation| conversation.snoozed_until if conversation&.snoozed? }.min
  end

  def self.with_label_tag_ids(tag_ids = nil, accessible_conversations: nil)
    return none if tag_ids&.empty?

    tag_ids_sql = tag_ids&.map(&:to_i)&.join(', ')
    contact_sql = "communication_threads.contact_id = ANY (#{Labels::ConversationScope.labeled_ids_sql('Contact', tag_ids_sql)})"
    linked_conv_sql = linked_labeled_conversations_sql(tag_ids_sql, accessible_conversations)
    accessible_thread_relation(accessible_conversations).where(Arel.sql("(#{contact_sql} OR #{linked_conv_sql})"))
  end

  def self.accessible_thread_relation(accessible_conversations)
    return all if accessible_conversations.nil?

    accessible_thread_ids = CommunicationThreadConversation
                            .where(conversation_id: accessible_conversations.reselect(:id))
                            .select(:communication_thread_id)
    where(id: accessible_thread_ids)
  end

  def self.linked_labeled_conversations_sql(tag_ids_sql, accessible_conversations)
    conversation_ids_sql = Labels::ConversationScope.labeled_ids_sql('Conversation', tag_ids_sql)
    if accessible_conversations.nil?
      return 'communication_threads.id IN (' \
             'SELECT ctc_label.communication_thread_id FROM communication_thread_conversations ctc_label ' \
             "WHERE ctc_label.conversation_id = ANY (#{conversation_ids_sql}))"
    end

    accessible_labeled_sql = accessible_conversations
                             .where(Arel.sql("conversations.id = ANY (#{conversation_ids_sql})"))
                             .reselect('conversations.id')
                             .to_sql
    'communication_threads.id IN (' \
      'SELECT ctc_label.communication_thread_id FROM communication_thread_conversations ctc_label ' \
      "WHERE ctc_label.conversation_id IN (#{accessible_labeled_sql}))"
  end
  private_class_method :accessible_thread_relation, :linked_labeled_conversations_sql

  private

  def ensure_display_id
    return if display_id.present? || account.blank?

    account.with_lock do
      self.display_id = self.class.where(account_id: account_id).maximum(:display_id).to_i + 1
    end
  end
end
