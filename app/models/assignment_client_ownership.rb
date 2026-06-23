# frozen_string_literal: true

# == Schema Information
#
# Table name: assignment_client_ownerships
#
#  id                   :bigint           not null, primary key
#  expires_at           :datetime
#  last_assigned_at     :datetime         not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#  assignment_policy_id :bigint
#  contact_id           :bigint           not null
#  user_id              :bigint           not null
#
# Indexes
#
#  idx_assignment_ownerships_account_contact         (account_id,contact_id) UNIQUE
#  idx_assignment_ownerships_account_user            (account_id,user_id)
#  index_assignment_client_ownerships_on_account_id  (account_id)
#  index_assignment_client_ownerships_on_contact_id  (contact_id)
#  index_assignment_client_ownerships_on_expires_at  (expires_at)
#  index_assignment_client_ownerships_on_user_id     (user_id)
#  index_assignment_ownerships_on_policy_id          (assignment_policy_id)
#
# Foreign Keys
#
#  fk_rails_assignment_client_ownerships_account  (account_id => accounts.id)
#  fk_rails_assignment_client_ownerships_contact  (contact_id => contacts.id)
#  fk_rails_assignment_client_ownerships_policy   (assignment_policy_id => assignment_policies.id) ON DELETE => nullify
#  fk_rails_assignment_client_ownerships_user     (user_id => users.id)
#
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
