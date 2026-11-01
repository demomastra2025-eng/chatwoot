# frozen_string_literal: true

class Billing::AccountProfile < ApplicationRecord
  KNP_CODES = %w[859 851].freeze

  belongs_to :account, inverse_of: :billing_account_profile

  encrypts :bcc_card_token if Chatwoot.encryption_configured?

  before_validation :normalize_attributes

  validates :account_id, uniqueness: true
  validates :billing_tax_id, format: { with: Billing::TAX_ID_FORMAT }, allow_nil: true
  validates :billing_day, numericality: { only_integer: true, in: 1..31 }, allow_nil: true
  validates :custom_monthly_price_minor, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :extra_seats_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :extra_storage_packs_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :partner_commission_rate_pct, numericality: { only_integer: true, in: 0..100 }
  validates :knp_code, presence: true
  validates :billing_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true

  after_save :sync_account_attributes!

  scope :enabled, -> { where(billing_enabled: true) }

  def effective_tax_id
    billing_tax_id.presence || account&.organization&.bin
  end

  def effective_legal_name
    legal_name.presence || account&.organization&.legal_name.presence || account&.name
  end

  def effective_contract_number
    contract_number.presence || account&.organization&.contract_number
  end

  def effective_billing_email
    billing_email.presence || organization_or_admin_email
  end

  def advance_paid_until!(paid_date:)
    self.billing_day ||= (paid_until || paid_date).day
    use_anchor = paid_until.present? && paid_date <= paid_until
    self.paid_until = next_period_end_from([paid_until, paid_date].compact.max, anchor_from_paid_until: use_anchor)
    self.payment_overdue_banner = false
    self.overdue_invoice_number = nil
    save!
  end

  def next_period_end_from(base_date, anchor_from_paid_until: true)
    return base_date + 1.month unless anchor_from_paid_until && billing_day.present?

    target = base_date.next_month
    Date.new(target.year, target.month, [billing_day, target.end_of_month.day].min)
  end

  private

  def organization_or_admin_email
    return unless account

    account.organization&.billing_email.presence || account.administrators.first&.email
  end

  def normalize_attributes
    self.billing_tax_id = Billing.normalize_tax_id(billing_tax_id)
    normalize_text_fields
    self.knp_code = knp_code.to_s.strip.presence || Billing::Config::DEFAULT_KNP
    self.billing_day ||= paid_until.day if paid_until.present?
  end

  def normalize_text_fields
    self.legal_name = legal_name.to_s.squish.presence
    self.contract_number = contract_number.to_s.squish.presence
    self.billing_email = billing_email.to_s.squish.presence
  end

  def sync_account_attributes!
    return unless account
    return unless saved_change_to_paid_until? || saved_change_to_payment_overdue_banner? || saved_change_to_overdue_invoice_number?

    current = account.custom_attributes.to_h
    merged = current.merge(
      'paid_until' => paid_until&.iso8601,
      'payment_overdue_banner' => payment_overdue_banner,
      'overdue_invoice_number' => overdue_invoice_number
    ).compact
    account.update!(custom_attributes: merged) if merged != current
  end
end
