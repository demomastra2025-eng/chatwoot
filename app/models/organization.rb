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
  # Kazakhstan business identification number: 12 digits, the last one is a control digit of the first eleven
  BIN_FORMAT = /\A\d{12}\z/
  # The weights of the control digit: the first pass counts 1..11, the second pass (after a remainder of 10) 3..11, 1, 2
  BIN_WEIGHTS = [(1..11).to_a, [3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2]].freeze
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
  validate :bin_control_digit_matches
  validates :billing_email, format: { with: URI::MailTo::EMAIL_REGEXP }, length: { maximum: NAME_LENGTH }, allow_nil: true

  # The BIN as it is typed in forms and spreadsheets ("9801 4000 0123") without the spaces; blank becomes nil
  def self.normalize_bin(value)
    value.to_s.gsub(/[[:space:]]+/, '').presence
  end

  # The control digit of the first eleven digits of a БИН: the sum of the digits times their weights 1..11, modulo 11.
  # A remainder of 10 is counted again with the weights 3..11, 1, 2. Nil when that is 10 as well: no БИН starts so.
  def self.bin_control_digit(first_eleven)
    digits = first_eleven.to_s.chars.map(&:to_i)
    BIN_WEIGHTS.each do |weights|
      remainder = digits.zip(weights).sum { |digit, weight| digit * weight } % 11
      return remainder if remainder < 10
    end
    nil
  end

  private

  # A BIN with a wrong control digit is a typo: it cannot belong to any company. Only a BIN of the right shape is checked,
  # so a short or a lettered one gets the one message about its format.
  def bin_control_digit_matches
    return unless bin&.match?(BIN_FORMAT)
    return if self.class.bin_control_digit(bin.first(11)) == bin.last.to_i

    errors.add(:bin, :invalid_control_digit)
  end

  # Blank optional values are stored as NULL (so the unique BIN index only holds filled-in BINs)
  def normalize_fields
    %i[name legal_name contract_number phone billing_email].each { |attribute| self[attribute] = self[attribute].to_s.squish.presence }
    %i[address notes].each { |attribute| self[attribute] = self[attribute].to_s.strip.presence }
    self.bin = self.class.normalize_bin(bin)
  end
end
