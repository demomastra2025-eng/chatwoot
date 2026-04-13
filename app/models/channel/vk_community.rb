# == Schema Information
#
# Table name: channel_vk_community
#
#  id                 :bigint           not null, primary key
#  access_token       :string
#  api_version        :string           default("5.199"), not null
#  confirmation_token :string
#  secret             :string
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :integer          not null
#  callback_id        :string           not null
#  group_id           :bigint           not null
#
# Indexes
#
#  index_channel_vk_community_on_callback_id  (callback_id) UNIQUE
#  index_channel_vk_community_on_group_id     (group_id) UNIQUE
#

class Channel::VkCommunity < ApplicationRecord
  include Channelable

  self.table_name = 'channel_vk_community'

  EDITABLE_ATTRS = %i[group_id access_token secret confirmation_token api_version callback_id].freeze
  IMMUTABLE_RUNTIME_ATTRS = %i[group_id].freeze

  encrypts :access_token if Chatwoot.encryption_configured?
  encrypts :secret if Chatwoot.encryption_configured?
  encrypts :confirmation_token if Chatwoot.encryption_configured?

  validates :group_id, presence: true, uniqueness: true, numericality: { only_integer: true, greater_than: 0 }
  validates :api_version, presence: true
  validates :callback_id, presence: true, uniqueness: true
  validates :access_token, presence: true
  validates :secret, presence: true
  validates :confirmation_token, presence: true
  validate :runtime_identity_is_immutable, on: :update

  before_validation :ensure_defaults!

  def name
    'VK'
  end

  def generated_inbox_name
    "vk_#{group_id}"
  end

  def callback_webhook_url
    "#{frontend_url}/webhooks/vk/#{callback_id}"
  end

  def api_client
    @api_client ||= VkCommunity::ApiClient.new(channel: self)
  end

  private

  def ensure_defaults!
    self.api_version = api_version.presence || '5.199'
    self.callback_id = callback_id.presence || SecureRandom.hex(16)
  end

  def runtime_identity_is_immutable
    IMMUTABLE_RUNTIME_ATTRS.each do |attr|
      next unless will_save_change_to_attribute?(attr)

      errors.add(attr, 'cannot be changed after creation')
    end
  end

  def frontend_url
    ENV.fetch('FRONTEND_URL', nil)
  end
end
