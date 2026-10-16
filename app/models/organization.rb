# == Schema Information
#
# Table name: organizations
#
#  id                :bigint           not null, primary key
#  address           :text
#  bin               :string
#  billing_email     :string
#  contract_date     :date
#  contract_number   :string
#  custom_attributes :jsonb            not null
#  legal_name        :string
#  name              :string           not null
#  notes             :text
#  phone             :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
# Indexes
#
#  index_organizations_on_bin         (bin) UNIQUE
#  index_organizations_on_lower_name  (lower((name)::text))
#
# The paying parent of accounts: requisites, BIN and contract. Its accounts are its branches or departments; each
# account keeps its own plan, limits and channels. An account without an organization works exactly as before.
class Organization < ApplicationRecord
  # Kazakhstan business identification number: 12 digits
  BIN_FORMAT = /\A\d{12}\z/
  NAME_LENGTH = 255

  # Deleting an organization that still has accounts is refused; the accounts are unlinked first.
  has_many :accounts, dependent: :restrict_with_error

  before_validation :normalize_fields

  validates :name, presence: true, length: { maximum: NAME_LENGTH }
  validates :legal_name, length: { maximum: NAME_LENGTH }
  validates :contract_number, length: { maximum: 100 }
  validates :phone, length: { maximum: 50 }
  validates :address, length: { maximum: 1000 }
  validates :notes, length: { maximum: 5000 }
  validates :bin, format: { with: BIN_FORMAT, message: :invalid_bin }, allow_nil: true
  validates :bin, uniqueness: true, allow_nil: true
  validates :billing_email, format: { with: URI::MailTo::EMAIL_REGEXP }, length: { maximum: NAME_LENGTH }, allow_nil: true

  # The BIN as it is typed in forms and spreadsheets ("9801 4000 0123") without the spaces; blank becomes nil
  def self.normalize_bin(value)
    value.to_s.gsub(/[[:space:]]+/, '').presence
  end

  private

  # Blank optional values are stored as NULL (so the unique BIN index only holds filled-in BINs)
  def normalize_fields
    %i[name legal_name contract_number phone billing_email].each { |attribute| self[attribute] = self[attribute].to_s.squish.presence }
    %i[address notes].each { |attribute| self[attribute] = self[attribute].to_s.strip.presence }
    self.bin = self.class.normalize_bin(bin)
  end
end
