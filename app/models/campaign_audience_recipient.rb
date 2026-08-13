# == Schema Information
#
# Table name: campaign_audience_recipients
#
#  id                          :bigint           not null, primary key
#  contact_created             :boolean          default(FALSE), not null
#  normalized_phone_number     :string           not null
#  source_row                  :integer          not null
#  created_at                  :datetime         not null
#  updated_at                  :datetime         not null
#  account_id                  :bigint           not null
#  campaign_audience_import_id :bigint           not null
#  contact_id                  :bigint
#
# Indexes
#
#  idx_campaign_audience_recipients_import_contact   (campaign_audience_import_id,contact_id) UNIQUE
#  idx_campaign_audience_recipients_import_phone     (campaign_audience_import_id,normalized_phone_number) UNIQUE
#  idx_campaign_audience_recipients_on_import        (campaign_audience_import_id)
#  index_campaign_audience_recipients_on_account_id  (account_id)
#  index_campaign_audience_recipients_on_contact_id  (contact_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (campaign_audience_import_id => campaign_audience_imports.id) ON DELETE => cascade
#  fk_rails_...  (contact_id => contacts.id) ON DELETE => nullify
#
class CampaignAudienceRecipient < ApplicationRecord
  belongs_to :campaign_audience_import
  belongs_to :account
  belongs_to :contact, optional: true

  validates :normalized_phone_number, format: { with: Contacts::PhoneNumberNormalizer::E164_PATTERN }
  validates :source_row, numericality: { only_integer: true, greater_than: 0 }
  validates :contact_id, uniqueness: { scope: :campaign_audience_import_id }, allow_nil: true
  validates :normalized_phone_number, uniqueness: { scope: :campaign_audience_import_id }
  validate :ownership_is_consistent

  private

  def ownership_is_consistent
    return if campaign_audience_import.blank? || contact.blank?
    return if account_id == campaign_audience_import.account_id && account_id == contact.account_id

    errors.add(:account_id, 'must match the import and contact account')
  end
end
