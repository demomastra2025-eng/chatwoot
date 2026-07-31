# frozen_string_literal: true

# == Schema Information
#
# Table name: account_user_lifecycle_snapshots
#
#  id                       :bigint           not null, primary key
#  auto_offline             :boolean          default(TRUE), not null
#  availability             :string           not null
#  deactivated_at           :datetime         not null
#  inbox_ids                :jsonb            not null
#  reactivated_at           :datetime
#  role                     :string           not null
#  team_ids                 :jsonb            not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  account_id               :bigint           not null
#  agent_capacity_policy_id :bigint
#  custom_role_id           :bigint
#  deactivated_by_id        :bigint
#  user_id                  :bigint           not null
#
# Indexes
#
#  index_account_user_lifecycle_snapshots_active                (account_id,user_id) UNIQUE WHERE (reactivated_at IS NULL)
#  index_account_user_lifecycle_snapshots_on_account_id         (account_id)
#  index_account_user_lifecycle_snapshots_on_deactivated_at     (deactivated_at)
#  index_account_user_lifecycle_snapshots_on_deactivated_by_id  (deactivated_by_id)
#  index_account_user_lifecycle_snapshots_on_user_id            (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (deactivated_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class AccountUserLifecycleSnapshot < ApplicationRecord
  belongs_to :account
  belongs_to :user
  belongs_to :deactivated_by, class_name: 'User', optional: true

  scope :active, -> { where(reactivated_at: nil) }

  validates :role, inclusion: { in: AccountUser.roles.keys }
  validates :availability, inclusion: { in: AccountUser.availabilities.keys }
  validates :deactivated_at, presence: true
  validates :user_id, uniqueness: {
    scope: :account_id,
    conditions: -> { where(reactivated_at: nil) }
  }, if: -> { reactivated_at.nil? }
end
