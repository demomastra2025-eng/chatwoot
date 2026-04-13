# == Schema Information
#
# Table name: contact_channel_profiles
#
#  id               :bigint           not null, primary key
#  avatar_url       :text
#  channel_type     :string           not null
#  display_name     :string
#  email            :string
#  identifier       :string
#  last_synced_at   :datetime
#  phone_number     :string
#  profile_data     :jsonb            not null
#  provider         :string           not null
#  username         :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  contact_id       :bigint           not null
#  contact_inbox_id :bigint           not null
#  inbox_id         :bigint           not null
#  source_id        :text             not null
#
# Indexes
#
#  idx_contact_channel_profiles_contact_inbox         (contact_id,inbox_id)
#  idx_contact_channel_profiles_provider_source       (account_id,provider,source_id)
#  idx_contact_channel_profiles_unique_contact_inbox  (contact_inbox_id) UNIQUE
#  index_contact_channel_profiles_on_account_id       (account_id)
#  index_contact_channel_profiles_on_contact_id       (contact_id)
#  index_contact_channel_profiles_on_inbox_id         (inbox_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (contact_inbox_id => contact_inboxes.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#
class ContactChannelProfile < ApplicationRecord
  belongs_to :account
  belongs_to :contact
  belongs_to :contact_inbox
  belongs_to :inbox

  before_validation :sync_context_from_contact_inbox

  validates :account_id, :contact_id, :contact_inbox_id, :inbox_id, :channel_type, :provider, :source_id, presence: true
  validates :contact_inbox_id, uniqueness: true
  validates :display_name, length: { maximum: 255 }
  validates :username, :phone_number, :email, :identifier, length: { maximum: 255 }

  def name
    display_name
  end

  def push_event_data
    profile_identity_data.merge(
      profile_display_data,
      profile_data: profile_data || {},
      last_synced_at: last_synced_at&.to_i
    ).compact
  end

  private

  def profile_identity_data
    {
      id: id,
      account_id: account_id,
      contact_id: contact_id,
      contact_inbox_id: contact_inbox_id,
      inbox_id: inbox_id,
      channel_type: channel_type,
      provider: provider,
      source_id: source_id,
      identifier: identifier
    }
  end

  def profile_display_data
    {
      name: display_name,
      display_name: display_name,
      avatar_url: avatar_url,
      thumbnail: avatar_url,
      username: username,
      phone_number: phone_number,
      email: email
    }
  end

  def sync_context_from_contact_inbox
    return if contact_inbox.blank?

    sync_record_context
    sync_provider_context
  end

  def sync_record_context
    self.contact = contact_inbox.contact if contact_id.blank?
    self.inbox = contact_inbox.inbox if inbox_id.blank?
    self.account = resolved_account if account_id.blank?
  end

  def sync_provider_context
    self.channel_type = inbox.channel_type if channel_type.blank? && inbox.present?
    self.source_id = contact_inbox.source_id if source_id.blank?
  end

  def resolved_account
    inbox&.account || contact&.account
  end
end
