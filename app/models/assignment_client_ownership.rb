# frozen_string_literal: true

class AssignmentClientOwnership < ApplicationRecord
  belongs_to :account
  belongs_to :contact
  belongs_to :user
  belongs_to :assignment_policy, optional: true

  validates :contact_id, uniqueness: { scope: :account_id }
  validates :last_assigned_at, presence: true

  scope :active, -> { where('expires_at IS NULL OR expires_at > ?', Time.current) }

  def active?
    expires_at.blank? || expires_at.future?
  end
end
