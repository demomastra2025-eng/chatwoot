# == Schema Information
#
# Table name: crm_deal_contacts
#
#  id         :bigint           not null, primary key
#  primary    :boolean          default(FALSE), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :bigint           not null
#  contact_id :bigint           not null
#  deal_id    :bigint           not null
#
# Indexes
#
#  index_crm_deal_contacts_on_account_contact  (account_id,contact_id)
#  index_crm_deal_contacts_on_account_id       (account_id)
#  index_crm_deal_contacts_on_contact_id       (contact_id)
#  index_crm_deal_contacts_on_deal_contact     (deal_id,contact_id) UNIQUE
#  index_crm_deal_contacts_on_deal_id          (deal_id)
#  index_crm_deal_contacts_on_primary_contact  (deal_id) UNIQUE WHERE ("primary" = true)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (deal_id => crm_deals.id)
#
class Crm::DealContact < ApplicationRecord
  self.table_name = 'crm_deal_contacts'

  belongs_to :account, class_name: '::Account'
  belongs_to :deal, class_name: '::Crm::Deal', inverse_of: :deal_contacts
  belongs_to :contact, class_name: '::Contact'

  validates :contact_id, uniqueness: { scope: :deal_id }
  validate :records_belong_to_account

  scope :ordered, -> { order(primary: :desc, id: :asc) }

  private

  def records_belong_to_account
    validate_account_match(:deal, deal)
    validate_account_match(:contact, contact)
  end

  def validate_account_match(attribute_name, record)
    return if record.blank? || record.account_id == account_id

    errors.add(attribute_name, 'must belong to the current account')
  end
end
