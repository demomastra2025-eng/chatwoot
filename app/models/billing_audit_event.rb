# == Schema Information
#
# Table name: billing_audit_events
#
#  id                 :bigint           not null, primary key
#  action             :string           not null
#  details            :jsonb            not null
#  occurred_at        :datetime         not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  billing_account_id :bigint           not null
#  super_admin_id     :integer
#
# Indexes
#
#  idx_billing_audit_events_account_time             (billing_account_id,occurred_at)
#  index_billing_audit_events_on_billing_account_id  (billing_account_id)
#  index_billing_audit_events_on_super_admin_id      (super_admin_id)
#
# Foreign Keys
#
#  fk_rails_...  (billing_account_id => billing_accounts.id)
#  fk_rails_...  (super_admin_id => users.id) ON DELETE => nullify
#
class BillingAuditEvent < ApplicationRecord
  belongs_to :billing_account
  belongs_to :super_admin, optional: true

  validates :action, :occurred_at, presence: true
  validate :details_is_object

  before_validation :set_occurred_at, on: :create
  before_update :prevent_mutation
  before_destroy :prevent_mutation

  private

  def set_occurred_at
    self.occurred_at ||= Time.current
  end

  def details_is_object
    errors.add(:details, 'must be an object') unless details.is_a?(Hash)
  end

  def prevent_mutation
    errors.add(:base, 'billing audit events are immutable')
    throw :abort
  end
end
