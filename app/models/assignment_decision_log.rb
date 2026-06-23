# frozen_string_literal: true

# == Schema Information
#
# Table name: assignment_decision_logs
#
#  id                   :bigint           not null, primary key
#  candidate_summaries  :jsonb            not null
#  decision_metadata    :jsonb            not null
#  outcome              :integer          default("assigned"), not null
#  reasons              :jsonb            not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#  assigned_user_id     :bigint
#  assignment_policy_id :bigint
#  conversation_id      :bigint           not null
#  inbox_id             :bigint           not null
#
# Indexes
#
#  idx_assignment_decision_logs_account_created_at        (account_id,created_at)
#  idx_assignment_decision_logs_conversation_created_at   (conversation_id,created_at)
#  idx_assignment_decision_logs_inbox_outcome_created_at  (inbox_id,outcome,created_at)
#  index_assignment_decision_logs_on_account_id           (account_id)
#  index_assignment_decision_logs_on_assigned_user_id     (assigned_user_id)
#  index_assignment_decision_logs_on_conversation_id      (conversation_id)
#  index_assignment_decision_logs_on_inbox_id             (inbox_id)
#  index_assignment_decision_logs_on_policy_id            (assignment_policy_id)
#
# Foreign Keys
#
#  fk_rails_assignment_decision_logs_account        (account_id => accounts.id)
#  fk_rails_assignment_decision_logs_assigned_user  (assigned_user_id => users.id) ON DELETE => nullify
#  fk_rails_assignment_decision_logs_conversation   (conversation_id => conversations.id)
#  fk_rails_assignment_decision_logs_inbox          (inbox_id => inboxes.id)
#  fk_rails_assignment_decision_logs_policy         (assignment_policy_id => assignment_policies.id) ON DELETE => nullify
#
class AssignmentDecisionLog < ApplicationRecord
  belongs_to :account
  belongs_to :inbox
  belongs_to :conversation
  belongs_to :assignment_policy, optional: true
  belongs_to :assigned_user, class_name: 'User', optional: true

  enum outcome: { assigned: 0, skipped: 1, failed: 2 }

  validates :outcome, presence: true
end
