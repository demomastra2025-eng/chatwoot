# frozen_string_literal: true

class AssignmentQuotaUsage < ApplicationRecord
  belongs_to :account
  belongs_to :user
  belongs_to :contact
  belongs_to :conversation, optional: true
  belongs_to :assignment_policy, optional: true

  validates :period_start, :period_end, presence: true
  validates :contact_id, uniqueness: { scope: [:account_id, :user_id, :period_start] }
end
