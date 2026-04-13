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
#  campaign_run_id     :bigint
#  contact_id          :bigint           not null
#  inbox_id            :bigint           not null
#  provider_message_id :string
#
# Indexes
#
#  index_campaign_deliveries_on_account_id                      (account_id)
#  index_campaign_deliveries_on_campaign_id                     (campaign_id)
#  index_campaign_deliveries_on_campaign_id_and_contact_id      (campaign_id,contact_id)
#  index_campaign_deliveries_on_campaign_run_id                 (campaign_run_id)
#  index_campaign_deliveries_on_campaign_run_id_and_contact_id  (campaign_run_id,contact_id) UNIQUE WHERE (campaign_run_id IS NOT NULL)
#  index_campaign_deliveries_on_contact_id                      (contact_id)
#  index_campaign_deliveries_on_inbox_id                        (inbox_id)
#  index_campaign_deliveries_on_provider_message_id             (provider_message_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (campaign_id => campaigns.id)
#  fk_rails_...  (campaign_run_id => campaign_runs.id)
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#

class CampaignDelivery < ApplicationRecord
  belongs_to :account
  belongs_to :campaign
  belongs_to :campaign_run, optional: true
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

  after_commit :sync_campaign_run_snapshot, on: [:create, :update]

  def self.track!(campaign:, contact:, target_identifier:, provider:, status:, campaign_run: nil, provider_message_id: nil, error_message: nil,
                  metadata: {})
    delivery = if campaign_run.present?
                 find_or_initialize_by(campaign_run: campaign_run, contact: contact)
               else
                 find_or_initialize_by(campaign: campaign, contact: contact)
               end
    delivery.account = campaign.account
    delivery.campaign = campaign
    delivery.inbox = campaign.inbox
    delivery.campaign_run = campaign_run if campaign_run.present?
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

  private

  def sync_campaign_run_snapshot
    return unless campaign_run_id?

    campaign_run.refresh_delivery_snapshot!
  end
end
