# frozen_string_literal: true

class AssignmentDecisionLog < ApplicationRecord
  belongs_to :account
  belongs_to :inbox
  belongs_to :conversation
  belongs_to :assignment_policy, optional: true
  belongs_to :assigned_user, class_name: 'User', optional: true

  enum outcome: { assigned: 0, skipped: 1, failed: 2 }

  validates :outcome, presence: true
end
