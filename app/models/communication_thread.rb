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

  private

  def ensure_display_id
    return if display_id.present? || account.blank?

    account.with_lock do
      self.display_id = self.class.where(account_id: account_id).maximum(:display_id).to_i + 1
    end
  end
end
