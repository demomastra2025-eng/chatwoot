# == Schema Information
#
# Table name: billing_account_workspaces
#
#  id                 :bigint           not null, primary key
#  detached_at        :datetime
#  metadata           :jsonb            not null
#  status             :string           default("active"), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :integer          not null
#  billing_account_id :bigint           not null
#
# Indexes
#
#  idx_billing_workspaces_one_active_account               (account_id) UNIQUE WHERE ((status)::text = 'active'::text)
#  index_billing_account_workspaces_on_account_id          (account_id)
#  index_billing_account_workspaces_on_billing_account_id  (billing_account_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (billing_account_id => billing_accounts.id)
#
class BillingAccountWorkspace < ApplicationRecord
  STATUSES = %w[active detached].freeze

  belongs_to :billing_account
  belongs_to :account

  enum :status, STATUSES.index_with(&:itself)

  validates :account_id, uniqueness: { conditions: -> { where(status: 'active') } }, if: :active?
  validate :metadata_is_object

  private

  def metadata_is_object
    errors.add(:metadata, 'must be an object') unless metadata.is_a?(Hash)
  end
end
