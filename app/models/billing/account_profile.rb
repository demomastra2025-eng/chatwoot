# frozen_string_literal: true

class Billing::AccountProfile < ApplicationRecord
  KNP_CODES = %w[859 851].freeze
  ACCOUNT_SYNC_SQL = <<~SQL.squish.freeze
    custom_attributes = (
      COALESCE(custom_attributes, '{}'::jsonb)
      - 'paid_until'
      - 'payment_overdue_banner'
      - 'overdue_invoice_number'
    ) || :patch::jsonb
  SQL

  self.filter_attributes += [:bcc_card_token]

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

  def serializable_hash(options = nil)
    super.except('bcc_card_token', :bcc_card_token)
  end

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

  def advance_paid_until!(paid_date:, invoice: nil)
    self.billing_day ||= (paid_until || invoice&.period_start || paid_date).day
    self.paid_until = compute_advanced_paid_until(paid_date, invoice)
    refresh_overdue_banner_state(invoice)
    save!
  end

  def next_period_end_from(base_date, anchor_from_paid_until: true)
    return base_date + 1.month unless anchor_from_paid_until && billing_day.present?

    target = base_date.next_month
    Date.new(target.year, target.month, [billing_day, target.end_of_month.day].min)
  end

  private

  def compute_advanced_paid_until(paid_date, invoice)
    if invoice
      [paid_until, invoice.period_end, next_period_end_from(invoice.period_start)].compact.max
    elsif paid_until.present?
      next_period_end_from(paid_until)
    else
      next_period_end_from(paid_date)
    end
  end

  def refresh_overdue_banner_state(settled_invoice)
    remaining = remaining_overdue_invoice(settled_invoice)
    if remaining
      self.payment_overdue_banner = true
      self.overdue_invoice_number = remaining.invoice_number
    else
      self.payment_overdue_banner = false
      self.overdue_invoice_number = nil
    end
  end

  def remaining_overdue_invoice(settled_invoice)
    return nil unless account

    scope = account.billing_invoices.where(status: 'overdue')
    scope = scope.where.not(id: settled_invoice.id) if settled_invoice&.id
    scope.order(:due_on, :id).first
  end

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

  # rubocop:disable Rails/SkipsModelValidations
  def sync_account_attributes!
    return unless account_id.present? && synced_fields_changed?

    patch = {
      'paid_until' => paid_until&.iso8601,
      'payment_overdue_banner' => payment_overdue_banner,
      'overdue_invoice_number' => overdue_invoice_number
    }.compact
    sql = Arel.sql(ActiveRecord::Base.sanitize_sql_array([ACCOUNT_SYNC_SQL, { patch: patch.to_json }]))
    Account.where(id: account_id).update_all(sql)
    refresh_loaded_account_attributes(patch)
  end
  # rubocop:enable Rails/SkipsModelValidations

  def synced_fields_changed?
    saved_change_to_paid_until? || saved_change_to_payment_overdue_banner? || saved_change_to_overdue_invoice_number?
  end

  def refresh_loaded_account_attributes(patch)
    return unless association(:account).loaded? && account

    was_changed = account.custom_attributes_changed?
    cleaned = account.custom_attributes.to_h.except('paid_until', 'payment_overdue_banner', 'overdue_invoice_number')
    account.custom_attributes = cleaned.merge(patch)
    account.clear_attribute_changes(['custom_attributes']) unless was_changed
  end
end
