# == Schema Information
#
# Table name: campaign_deliveries
#
#  id                  :bigint           not null, primary key
#  error_message       :text
#  last_status_at      :datetime
#  metadata            :jsonb            not null
#  provider            :string           not null
#  status              :integer          default("pending"), not null
#  target_identifier   :string
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#  campaign_id         :bigint           not null
#  contact_id          :bigint           not null
#  inbox_id            :bigint           not null
#  provider_message_id :string
#
# Indexes
#
#  index_campaign_deliveries_on_account_id                  (account_id)
#  index_campaign_deliveries_on_campaign_id                 (campaign_id)
#  index_campaign_deliveries_on_campaign_id_and_contact_id  (campaign_id,contact_id) UNIQUE
#  index_campaign_deliveries_on_contact_id                  (contact_id)
#  index_campaign_deliveries_on_inbox_id                    (inbox_id)
#  index_campaign_deliveries_on_provider_message_id         (provider_message_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (campaign_id => campaigns.id)
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#

class CampaignDelivery < ApplicationRecord
  belongs_to :account
  belongs_to :campaign
  belongs_to :contact
  belongs_to :inbox

  enum status: {
    pending: 0,
    submitted: 1,
    sent: 2,
    delivered: 3,
    read: 4,
    failed: 5,
    skipped: 6
  }

  validates :provider, presence: true
  validates :status, presence: true

  def self.track!(campaign:, contact:, target_identifier:, provider:, status:, provider_message_id: nil, error_message: nil, metadata: {})
    delivery = find_or_initialize_by(campaign: campaign, contact: contact)
    delivery.account = campaign.account
    delivery.inbox = campaign.inbox
    delivery.provider = provider
    delivery.target_identifier = target_identifier.presence || contact.phone_number
    delivery.mark_status!(
      status: status,
      provider_message_id: provider_message_id,
      error_message: error_message,
      metadata: metadata
    )
    delivery
  end

  def mark_status!(status:, provider_message_id: nil, error_message: nil, metadata: {})
    self.status = status
    self.provider_message_id = provider_message_id if provider_message_id.present?
    self.error_message = error_message if error_message.present?
    self.metadata = (self.metadata || {}).merge(metadata.compact)
    self.last_status_at = Time.current
    save!
  end
end
