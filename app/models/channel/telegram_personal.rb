# == Schema Information
#
# Table name: channel_telegram_personal
#
#  id                 :bigint           not null, primary key
#  api_hash           :string
#  connection_state   :string           default("disconnected"), not null
#  last_error         :text
#  last_synced_at     :datetime
#  lifecycle_state    :string           default("pending_auth"), not null
#  phone_number       :string           not null
#  runtime_state      :jsonb            not null
#  string_session     :text
#  webhook_identifier :string           not null
#  webhook_secret     :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :integer          not null
#  api_id             :integer          not null
#
# Indexes
#
#  index_channel_telegram_personal_on_account_id          (account_id)
#  index_channel_telegram_personal_on_account_phone       (account_id,phone_number) UNIQUE
#  index_channel_telegram_personal_on_webhook_identifier  (webhook_identifier) UNIQUE
#

class Channel::TelegramPersonal < ApplicationRecord
  include Channelable
  include TelegramPersonalRuntimeState

  self.table_name = 'channel_telegram_personal'

  EDITABLE_ATTRS = [
    :api_id,
    :api_hash,
    :phone_number,
    :string_session,
    :calling_enabled,
    { runtime_state: [:sync_groups, :calling_enabled, { ignored_chat_ids: [] }] }
  ].freeze
  CONNECTION_STATES = %w[disconnected connecting connected auth_required failed flood_wait].freeze
  LIFECYCLE_STATES = %w[pending_auth code_sent qr_ready qr_expired password_required connected disconnected failed].freeze
  IMMUTABLE_RUNTIME_ATTRS = %i[api_id phone_number].freeze

  has_secure_token :webhook_identifier
  has_secure_token :webhook_secret

  encrypts :api_hash if Chatwoot.encryption_configured?
  encrypts :string_session if Chatwoot.encryption_configured?

  validates :api_id, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  # rubocop:disable Rails/I18nLocaleTexts
  validates :phone_number,
            presence: true,
            uniqueness: { scope: :account_id },
            format: { with: /\A\+\d{6,15}\z/, message: 'must be in E.164 format' }
  # rubocop:enable Rails/I18nLocaleTexts
  validates :connection_state, inclusion: { in: CONNECTION_STATES }
  validates :lifecycle_state, inclusion: { in: LIFECYCLE_STATES }
  validates :webhook_identifier, presence: true, uniqueness: true
  validates :webhook_secret, presence: true
  validate :api_credentials_present
  validate :runtime_identity_is_immutable, on: :update

  before_validation :ensure_defaults!

  def self.default_api_id
    ENV.fetch('TELEGRAM_PERSONAL_DEFAULT_API_ID', nil).presence&.to_i
  end

  def self.default_api_hash
    ENV.fetch('TELEGRAM_PERSONAL_DEFAULT_API_HASH', nil).presence
  end

  def name
    'Telegram Personal'
  end

  def generated_inbox_name
    phone_number.delete_prefix('+')
  end

  def callback_webhook_url
    "#{frontend_url}/webhooks/telegram_personal/#{webhook_identifier}"
  end

  def resolved_api_id
    api_id.presence || self.class.default_api_id
  end

  def resolved_api_hash
    api_hash.presence || self.class.default_api_hash
  end

  def uses_default_api_credentials?
    api_id.blank? || api_hash.blank?
  end

  def update_message(message:, content:)
    TelegramPersonal::GatewayClient.new(channel: self).edit_message!(
      message: message,
      content: content
    )
  end

  def delete_message(message:)
    TelegramPersonal::GatewayClient.new(channel: self).delete_message!(message)
  end

  def teardown_runtime!
    TelegramPersonal::GatewayClient.new(channel: self).teardown_channel!
  rescue TelegramPersonal::GatewayClient::GatewayError => e
    Rails.logger.warn("[TELEGRAM PERSONAL] Failed to tear down runtime for channel #{id}: #{e.message}")
    true
  end

  def mark_pending_deletion!(timestamp: Time.current)
    update!(
      connection_state: 'disconnected',
      lifecycle_state: 'disconnected',
      last_error: nil,
      last_synced_at: timestamp
    )
  end

  def apply_runtime_update!(attrs = {})
    next_attrs = attrs.compact
    next_attrs[:last_error] = nil if clear_last_error?(attrs, next_attrs)
    next_attrs[:runtime_state] = normalize_runtime_state(next_attrs[:runtime_state]) if next_attrs.key?(:runtime_state)

    update!(next_attrs)
  end

  def clear_last_error?(attrs, next_attrs)
    return attrs[:last_error].blank? if attrs.key?(:last_error)

    next_attrs[:connection_state] == 'connected' && (next_attrs[:lifecycle_state] || lifecycle_state) == 'connected'
  end

  private

  def ensure_defaults!
    self.api_id ||= self.class.default_api_id
    self.api_hash ||= self.class.default_api_hash
    self.runtime_state = normalize_runtime_state(runtime_state)
    self.connection_state ||= 'disconnected'
    self.lifecycle_state ||= 'pending_auth'
    self.webhook_identifier ||= self.class.generate_unique_secure_token
    self.webhook_secret ||= self.class.generate_unique_secure_token
  end

  def api_credentials_present
    errors.add(:api_id, 'must be present or configured globally') if resolved_api_id.blank?
    errors.add(:api_hash, 'must be present or configured globally') if resolved_api_hash.blank?
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
