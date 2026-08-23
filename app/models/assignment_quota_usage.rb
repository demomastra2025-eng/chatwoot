# frozen_string_literal: true

# == Schema Information
#
# Table name: assignment_quota_usages
#
#  id                   :bigint           not null, primary key
#  period_end           :date             not null
#  period_start         :date             not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#  assignment_policy_id :bigint
#  contact_id           :bigint           not null
#  conversation_id      :bigint
#  user_id              :bigint           not null
#
# Indexes
#
#  idx_assignment_quota_usages_account_user_period    (account_id,user_id,period_start)
#  idx_assignment_quota_usages_unique_contact_period  (account_id,user_id,contact_id,period_start) UNIQUE
#  index_assignment_quota_usages_on_account_id        (account_id)
#  index_assignment_quota_usages_on_contact_id        (contact_id)
#  index_assignment_quota_usages_on_conversation_id   (conversation_id)
#  index_assignment_quota_usages_on_policy_id         (assignment_policy_id)
#  index_assignment_quota_usages_on_user_id           (user_id)
#
# Foreign Keys
#
#  fk_rails_assignment_quota_usages_account       (account_id => accounts.id)
#  fk_rails_assignment_quota_usages_contact       (contact_id => contacts.id) ON DELETE => cascade
#  fk_rails_assignment_quota_usages_conversation  (conversation_id => conversations.id)
#  fk_rails_assignment_quota_usages_policy        (assignment_policy_id => assignment_policies.id) ON DELETE => nullify
#  fk_rails_assignment_quota_usages_user          (user_id => users.id)
#
class AssignmentQuotaUsage < ApplicationRecord
  belongs_to :account
  belongs_to :user
  belongs_to :contact
  belongs_to :conversation, optional: true
  belongs_to :assignment_policy, optional: true

  validates :period_start, :period_end, presence: true
  validates :contact_id, uniqueness: { scope: [:account_id, :user_id, :period_start] }
end
