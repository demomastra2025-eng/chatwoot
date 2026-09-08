# == Schema Information
#
# Table name: billing_account_memberships
#
#  id                 :bigint           not null, primary key
#  role               :string           not null
#  status             :string           default("active"), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  billing_account_id :bigint           not null
#  user_id            :bigint           not null
#
# Indexes
#
#  idx_billing_memberships_account_user                     (billing_account_id,user_id) UNIQUE
#  idx_billing_memberships_one_active_owner                 (billing_account_id) UNIQUE WHERE (((role)::text = 'owner'::text) AND ((status)::text = 'active'::text))
#  index_billing_account_memberships_on_billing_account_id  (billing_account_id)
#  index_billing_account_memberships_on_user_id             (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (billing_account_id => billing_accounts.id)
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class BillingAccountMembership < ApplicationRecord
  ROLES = %w[owner billing_admin viewer].freeze
  STATUSES = %w[active inactive].freeze

  belongs_to :billing_account
  belongs_to :user

  enum :role, ROLES.index_with(&:itself)
  enum :status, STATUSES.index_with(&:itself)

  validates :user_id, uniqueness: { scope: :billing_account_id }
  validate :single_active_owner

  private

  def single_active_owner
    return unless owner? && active?

    relation = self.class.where(billing_account_id: billing_account_id, role: 'owner', status: 'active')
    relation = relation.where.not(id: id) if persisted?
    errors.add(:role, 'already has an active owner') if relation.exists?
  end
end
