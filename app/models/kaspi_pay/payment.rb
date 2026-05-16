# == Schema Information
#
# Table name: kaspi_pay_payments
#
#  id                  :bigint           not null, primary key
#  amount              :integer          not null
#  currency            :string           default("KZT"), not null
#  expires_at          :datetime
#  failed_at           :datetime
#  idempotency_key     :string
#  kaspi_order_number  :string
#  metadata            :jsonb            not null
#  paid_at             :datetime
#  payment_type        :string           not null
#  qr_token            :text
#  receipt_url         :string
#  source_type         :string
#  status              :string           default("pending"), not null
#  status_description  :string
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#  integration_hook_id :bigint           not null
#  kaspi_operation_id  :string
#  source_id           :bigint
#
# Indexes
#
#  index_kaspi_pay_payments_on_account_id                         (account_id)
#  index_kaspi_pay_payments_on_account_id_and_idempotency_key     (account_id,idempotency_key) UNIQUE WHERE (idempotency_key IS NOT NULL)
#  index_kaspi_pay_payments_on_account_id_and_kaspi_operation_id  (account_id,kaspi_operation_id) UNIQUE WHERE (kaspi_operation_id IS NOT NULL)
#  index_kaspi_pay_payments_on_account_id_and_status              (account_id,status)
#  index_kaspi_pay_payments_on_integration_hook_id                (integration_hook_id)
#  index_kaspi_pay_payments_on_source                             (source_type,source_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (integration_hook_id => integrations_hooks.id)
#
class KaspiPay::Payment < ApplicationRecord
  self.table_name = 'kaspi_pay_payments'

  PAYMENT_TYPES = %w[qr invoice].freeze
  STATUSES = %w[pending paid expired failed cancelled refunded].freeze
  FINAL_STATUSES = %w[paid expired failed cancelled refunded].freeze

  belongs_to :account
  belongs_to :integration_hook, class_name: 'Integrations::Hook'
  belongs_to :source, polymorphic: true, optional: true

  before_validation :sync_account_id

  validates :amount, numericality: { greater_than: 0, only_integer: true }
  validates :currency, presence: true
  validates :payment_type, inclusion: { in: PAYMENT_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :kaspi_operation_id, uniqueness: { scope: :account_id }, allow_blank: true
  validates :idempotency_key, uniqueness: { scope: :account_id }, allow_blank: true
  validate :integration_hook_belongs_to_account
  validate :source_belongs_to_account

  scope :active, -> { where.not(status: FINAL_STATUSES) }

  def final_status?
    status.in?(FINAL_STATUSES)
  end

  alias final_status final_status?

  private

  def sync_account_id
    self.account_id = integration_hook.account_id if integration_hook.present?
  end

  def integration_hook_belongs_to_account
    return if account_id.blank? || integration_hook.blank?
    return if integration_hook.account_id == account_id

    errors.add(:integration_hook_id, 'must belong to the current account')
  end

  def source_belongs_to_account
    return if account_id.blank? || source.blank? || !source.respond_to?(:account_id)
    return if source.account_id == account_id

    errors.add(:source, 'must belong to the current account')
  end
end
