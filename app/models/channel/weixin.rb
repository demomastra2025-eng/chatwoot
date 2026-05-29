# == Schema Information
#
# Table name: channel_weixins
#
#  id                  :bigint           not null, primary key
#  connection_state    :string           default("disconnected"), not null
#  context_token       :text
#  context_tokens      :jsonb            not null
#  display_name        :string
#  ilink_token         :text
#  last_error          :text
#  last_synced_at      :datetime
#  lifecycle_state     :string           default("pending_auth"), not null
#  runtime_state       :jsonb            not null
#  token_fingerprint   :string
#  webhook_identifier  :string           not null
#  webhook_secret      :string           not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :integer          not null
#  provider_account_id :string
#
# Indexes
#
#  index_channel_weixins_on_account_id                          (account_id)
#  index_channel_weixins_on_account_id_and_provider_account_id  (account_id,provider_account_id) UNIQUE WHERE (provider_account_id IS NOT NULL)
#  index_channel_weixins_on_account_id_and_token_fingerprint    (account_id,token_fingerprint) UNIQUE
#  index_channel_weixins_on_webhook_identifier                  (webhook_identifier) UNIQUE
#
class Channel::Weixin < ApplicationRecord
  self.table_name = 'channel_weixins'

  include Channelable

  EDITABLE_ATTRS = %i[ilink_token provider_account_id display_name context_token].freeze
  CONNECTION_STATES = %w[disconnected connecting connected auth_required failed rate_limited].freeze
  LIFECYCLE_STATES = %w[pending_auth qr_ready qr_scanned qr_expired connected disconnected failed].freeze
  IMMUTABLE_RUNTIME_ATTRS = %i[token_fingerprint provider_account_id].freeze
  SENSITIVE_ERROR_PATTERN = /(authorization|bearer|token|secret|password|api[_-]?key|connection[_-]?string)(["'\s:=]+)([^"'\s,}]+)/i
  DEFAULT_RUNTIME_STATE = {
    'qr_login_url' => nil,
    'qr_login_expires_at' => nil,
    'qr_login_state' => nil,
    'qr_login_requested_at' => nil,
    'qr_login_completed_at' => nil,
    'qr_login_expired_at' => nil,
    'qr_login_failed_at' => nil,
    'poller_state' => nil,
    'poller_started_at' => nil,
    'poller_stopped_at' => nil,
    'context_token_state' => nil,
    'last_update_id' => nil,
    'message_dedup' => {
      'ids' => [],
      'updated_at' => nil
    }
  }.freeze

  has_secure_token :webhook_identifier
  has_secure_token :webhook_secret

  encrypts :ilink_token if Chatwoot.encryption_configured?
  encrypts :context_token if Chatwoot.encryption_configured?
  encrypts :context_tokens if Chatwoot.encryption_configured?
  encrypts :webhook_secret if Chatwoot.encryption_configured?

  validates :account_id, presence: true
  validates :token_fingerprint, uniqueness: { scope: :account_id }, allow_blank: true
  validates :provider_account_id, uniqueness: { scope: :account_id }, allow_blank: true
  validates :connection_state, inclusion: { in: CONNECTION_STATES }
  validates :lifecycle_state, inclusion: { in: LIFECYCLE_STATES }
  validates :webhook_identifier, presence: true, uniqueness: true
  validates :webhook_secret, presence: true
  validate :runtime_identity_is_immutable, on: :update

  before_validation :ensure_defaults!

  def self.default_ilink_token
    ENV.fetch('WEIXIN_ILINK_DEFAULT_TOKEN', nil).presence
  end

  def name
    'Weixin Personal'
  end

  def generated_inbox_name
    display_name.presence || provider_account_id.presence || 'Weixin Personal'
  end

  def callback_webhook_url
    "#{frontend_url}/webhooks/weixin/#{webhook_identifier}"
  end

  def resolved_ilink_token
    ilink_token.presence || self.class.default_ilink_token
  end

  def runtime_state_payload
    normalize_runtime_state(runtime_state)
  end

  def context_tokens_payload
    normalize_context_tokens(context_tokens)
  end

  def context_token_for(peer_id)
    context_tokens_payload[peer_id.to_s].presence || context_token.presence
  end

  def remember_context_token!(peer_id, token)
    return if peer_id.blank? || token.blank?

    update!(
      context_token: token,
      context_tokens: context_tokens_payload.merge(peer_id.to_s => token)
    )
  end

  def teardown_runtime!
    Weixin::GatewayClient.new(channel: self).teardown_channel!
  rescue Weixin::GatewayClient::GatewayError => e
    Rails.logger.warn("[WEIXIN] Failed to tear down runtime for channel #{id}: #{e.message}")
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
    next_attrs[:last_error] = nil if attrs.key?(:last_error) && attrs[:last_error].nil?
    next_attrs[:runtime_state] = normalize_runtime_state(next_attrs[:runtime_state]) if next_attrs.key?(:runtime_state)
    next_attrs[:context_tokens] = normalize_context_tokens(next_attrs[:context_tokens]) if next_attrs.key?(:context_tokens)
    next_attrs[:last_error] = redact_error_message(next_attrs[:last_error]) if next_attrs.key?(:last_error) && next_attrs[:last_error].present?
    update!(next_attrs)
  end

  private

  def ensure_defaults!
    self.ilink_token ||= self.class.default_ilink_token
    self.token_fingerprint = fingerprint_for(resolved_ilink_token) if resolved_ilink_token.present?
    self.runtime_state = normalize_runtime_state(runtime_state)
    self.context_tokens = normalize_context_tokens(context_tokens)
    self.connection_state ||= 'disconnected'
    self.lifecycle_state ||= 'pending_auth'
    self.webhook_identifier ||= self.class.generate_unique_secure_token
    self.webhook_secret ||= self.class.generate_unique_secure_token
  end

  def runtime_identity_is_immutable
    IMMUTABLE_RUNTIME_ATTRS.each do |attr|
      next unless will_save_change_to_attribute?(attr)
      next if attr == :provider_account_id && attribute_in_database(attr).blank?
      next if attr == :token_fingerprint && attribute_in_database(attr).blank?

      errors.add(attr, 'cannot be changed after creation')
    end
  end

  def frontend_url
    ENV.fetch('FRONTEND_URL', nil)
  end

  def fingerprint_for(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def normalize_runtime_state(value)
    payload = (value || {}).deep_stringify_keys
    DEFAULT_RUNTIME_STATE.deep_merge(payload).tap do |runtime|
      runtime['last_update_id'] = runtime['last_update_id'].to_s if runtime['last_update_id'].present?
      runtime['message_dedup'] = DEFAULT_RUNTIME_STATE['message_dedup'].deep_merge(
        runtime['message_dedup'].is_a?(Hash) ? runtime['message_dedup'].deep_stringify_keys : {}
      )
      runtime['message_dedup']['ids'] = Array.wrap(runtime.dig('message_dedup', 'ids'))
                                             .map { |item| item.to_s.presence }
                                             .compact
      runtime.compact_blank!
    end
  end

  def normalize_context_tokens(value)
    (value || {}).deep_stringify_keys.transform_values { |token| token.to_s.presence }.compact
  end

  def redact_error_message(message)
    message.to_s.gsub(SENSITIVE_ERROR_PATTERN, '\\1\\2[REDACTED]')
  end
end
