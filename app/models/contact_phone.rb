class ContactPhone < ApplicationRecord
  E164_FORMAT = /\A\+[1-9]\d{1,14}\z/

  belongs_to :account
  belongs_to :contact
  belongs_to :owner_contact, class_name: 'Contact', optional: true

  scope :owned, -> { where(shared: false) }
  scope :secondary_owned, -> { where(primary: false, shared: false) }
  scope :shared_links, -> { where(shared: true) }

  before_validation :normalize_phone_number
  before_validation :prune_stale_primary_mirror_for_owned_phone, unless: :shared?

  validates :account_id, :contact_id, :phone_number, presence: true
  validates :phone_number, format: { with: E164_FORMAT }
  validates :phone_number, uniqueness: { scope: [:account_id, :contact_id] }
  validates :phone_number,
            uniqueness: { scope: :account_id, conditions: -> { where(shared: false) } },
            unless: :shared?
  validate :owner_contact_belongs_to_account

  def self.prune_stale_primary_mirrors!(account_id:, phone_numbers:)
    phones = Array(phone_numbers).compact_blank.uniq
    return if account_id.blank? || phones.empty?

    where(account_id: account_id, phone_number: phones, primary: true, shared: false)
      .where.not(contact_id: Contact.where(account_id: account_id, phone_number: phones).select(:id))
      .delete_all
  end

  private

  def normalize_phone_number
    return if phone_number.blank?

    normalized = ::Contacts::PhoneNumberNormalizer.normalize(phone_number, default_country: 'KZ') ||
                 ::Contacts::PhoneNumberNormalizer.normalize(phone_number)
    self.phone_number = normalized if normalized.present?
  end

  def prune_stale_primary_mirror_for_owned_phone
    return if account_id.blank? || phone_number.blank?

    self.class.prune_stale_primary_mirrors!(account_id: account_id, phone_numbers: [phone_number])
  end

  def owner_contact_belongs_to_account
    return if owner_contact_id.blank? || account_id.blank?
    return if Contact.exists?(id: owner_contact_id, account_id: account_id)

    errors.add(:owner_contact_id, :invalid)
  end
end
