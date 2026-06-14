# == Schema Information
#
# Table name: channel_linkedin_personal
#
#  id                 :bigint           not null, primary key
#  connection_state   :string           default("disconnected"), not null
#  csrf_token         :text
#  display_name       :string
#  jsessionid         :text
#  last_error         :text
#  last_synced_at     :datetime
#  li_at              :text
#  lifecycle_state    :string           default("pending_auth"), not null
#  profile_urn        :string           not null
#  runtime_state      :jsonb            not null
#  webhook_identifier :string           not null
#  webhook_secret     :string           not null
#  x_li_track         :text
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :integer          not null
#
# Indexes
#
#  index_channel_linkedin_personal_on_account_id                  (account_id)
#  index_channel_linkedin_personal_on_account_id_and_profile_urn  (account_id,profile_urn) UNIQUE
#  index_channel_linkedin_personal_on_webhook_identifier          (webhook_identifier) UNIQUE
#

class Channel::LinkedinPersonal < ApplicationRecord
  include Channelable

  self.table_name = 'channel_linkedin_personal'

  EDITABLE_ATTRS = %i[profile_urn display_name li_at jsessionid csrf_token x_li_track].freeze
  CONNECTION_STATES = %w[disconnected connecting connected auth_required failed rate_limited].freeze
  LIFECYCLE_STATES = %w[pending_auth connected disconnected failed].freeze
  IMMUTABLE_RUNTIME_ATTRS = %i[profile_urn].freeze
  DEFAULT_RUNTIME_STATE = {
    'history_sync_state' => nil,
    'history_sync_reason' => nil,
    'history_sync_requested_at' => nil,
    'history_sync_started_at' => nil,
    'history_sync_completed_at' => nil,
    'history_sync_failed_at' => nil,
    'history_sync_error' => nil,
    'history_sync_count' => 0,
    'history_thread_count' => 0,
    'history_sync_cursor' => nil,
    'contacts_sync_state' => nil,
    'contacts_sync_count' => 0,
    'last_poll_at' => nil,
    'last_message_at' => nil
  }.freeze

  has_secure_token :webhook_identifier
  has_secure_token :webhook_secret

  encrypts :li_at if Chatwoot.encryption_configured?
  encrypts :jsessionid if Chatwoot.encryption_configured?
  encrypts :csrf_token if Chatwoot.encryption_configured?
  encrypts :x_li_track if Chatwoot.encryption_configured?

  validates :profile_urn, presence: true, uniqueness: { scope: :account_id }
  validates :connection_state, inclusion: { in: CONNECTION_STATES }
  validates :lifecycle_state, inclusion: { in: LIFECYCLE_STATES }
  validates :webhook_identifier, presence: true, uniqueness: true
  validates :webhook_secret, presence: true
  validate :session_material_present
  validate :runtime_identity_is_immutable, on: :update

  before_validation :ensure_defaults!

  def name
    'LinkedIn'
  end

  def generated_inbox_name
    display_name.presence || profile_urn.to_s.split(':').last
  end

  def callback_webhook_url
    "#{frontend_url}/webhooks/linkedin_personal/#{webhook_identifier}"
  end

  def runtime_state_payload
    normalize_runtime_state(runtime_state)
  end

  def update_message(message:, content:)
    LinkedinPersonal::GatewayClient.new(channel: self).edit_message!(
      message: message,
      content: content
    )
  end

  def delete_message(message:)
    LinkedinPersonal::GatewayClient.new(channel: self).delete_message!(message)
  end

  def teardown_runtime!
    LinkedinPersonal::GatewayClient.new(channel: self).teardown_channel!
  rescue LinkedinPersonal::GatewayClient::GatewayError => e
    Rails.logger.warn("[LINKEDIN PERSONAL] Failed to tear down runtime for channel #{id}: #{e.message}")
    true
  end

  def apply_runtime_update!(attrs = {})
    next_attrs = attrs.compact
    next_attrs[:runtime_state] = normalize_runtime_state(next_attrs[:runtime_state]) if next_attrs.key?(:runtime_state)

    update!(next_attrs)
  end

  private

  def ensure_defaults!
    self.runtime_state = normalize_runtime_state(runtime_state)
    self.connection_state ||= 'disconnected'
    self.lifecycle_state ||= 'pending_auth'
    self.webhook_identifier ||= self.class.generate_unique_secure_token
    self.webhook_secret ||= self.class.generate_unique_secure_token
  end

  def session_material_present
    errors.add(:li_at, 'must be present') if li_at.blank?
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

  def normalize_runtime_state(value)
    payload = (value || {}).deep_stringify_keys
    DEFAULT_RUNTIME_STATE.deep_merge(payload).tap do |runtime|
      runtime['history_sync_count'] = runtime['history_sync_count'].to_i
      runtime['history_thread_count'] = runtime['history_thread_count'].to_i
      runtime['contacts_sync_count'] = runtime['contacts_sync_count'].to_i
    end
  end
end
