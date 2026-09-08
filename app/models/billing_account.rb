# == Schema Information
#
# Table name: billing_accounts
#
#  id               :bigint           not null, primary key
#  default_currency :string(3)        default("KZT"), not null
#  default_locale   :string           default("ru"), not null
#  metadata         :jsonb            not null
#  name             :string           not null
#  status           :string           default("active"), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
# Indexes
#
#  index_billing_accounts_on_status  (status)
#
class BillingAccount < ApplicationRecord
  STATUSES = %w[active past_due suspended closed].freeze
  PAYER_ATTRIBUTES = %w[payer_type legal_name tax_id billing_contact_name billing_email billing_phone billing_address billing_country].freeze

  store_accessor :metadata, *PAYER_ATTRIBUTES

  has_many :memberships, class_name: 'BillingAccountMembership', dependent: :restrict_with_error
  has_many :users, -> { merge(BillingAccountMembership.active) }, through: :memberships
  has_many :workspace_links, class_name: 'BillingAccountWorkspace', dependent: :restrict_with_error
  has_many :workspaces, -> { merge(BillingAccountWorkspace.active) }, through: :workspace_links, source: :account
  has_many :subscriptions, class_name: 'BillingSubscription', dependent: :restrict_with_error
  has_many :audit_events, class_name: 'BillingAuditEvent', dependent: :restrict_with_error

  enum :status, STATUSES.index_with(&:itself)

  validates :name, presence: true
  validates :default_currency, presence: true, format: { with: /\A[A-Z]{3}\z/ }
  validates :default_locale, presence: true
  validate :metadata_is_object

  with_options if: -> { metadata.is_a?(Hash) } do
    validates :payer_type, inclusion: { in: %w[individual business] }, allow_blank: true
    validates :billing_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
    validates :billing_country, format: { with: /\A[A-Z]{2}\z/ }, allow_blank: true
    validates(*PAYER_ATTRIBUTES.excluding('billing_address'), length: { maximum: 255 })
    validates :billing_address, length: { maximum: 1000 }
    validate :payer_details_are_strings
  end

  before_validation :normalize_payer_details

  def billing_details
    slice('name', 'status', 'default_currency', 'default_locale', *PAYER_ATTRIBUTES).deep_dup
  end

  # A suspended/incomplete subscription still has a displayable commercial state.
  # Entitlement resolution deliberately continues to use the entitling scope.
  def current_subscription
    ordered = subscriptions.order(created_at: :desc, id: :desc)
    ordered.entitling.first || ordered.first
  end

  private

  def normalize_payer_details
    return unless metadata.is_a?(Hash)

    PAYER_ATTRIBUTES.each do |field|
      value = public_send(field)
      public_send("#{field}=", value.strip.presence) if value.is_a?(String)
    end
    self.billing_country = billing_country.upcase if billing_country.is_a?(String)
  end

  def payer_details_are_strings
    PAYER_ATTRIBUTES.each do |field|
      value = public_send(field)
      errors.add(field, 'must be a string') unless value.nil? || value.is_a?(String)
    end
  end

  def metadata_is_object
    errors.add(:metadata, 'must be an object') unless metadata.is_a?(Hash)
  end
end
