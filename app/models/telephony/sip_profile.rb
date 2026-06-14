# frozen_string_literal: true

# == Schema Information
#
# Table name: telephony_sip_profiles
#
#  id                       :bigint           not null, primary key
#  agent_aor                :string
#  agent_ref                :string
#  availability_mode        :string           default("external_extension"), not null
#  credentials_ref          :string
#  enabled                  :boolean          default(TRUE), not null
#  fonoster_agent_ref       :string
#  fonoster_credentials_ref :string
#  internal_extension       :string           not null
#  last_synced_at           :datetime
#  managed_by               :string           default("onelink"), not null
#  metadata                 :jsonb            not null
#  ownership_status         :string           default("local"), not null
#  password_secret_ref      :string
#  sip_host                 :string
#  sip_username             :string
#  status                   :string           default("draft"), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  account_id               :bigint           not null
#  inbox_id                 :bigint
#  provider_connection_id   :bigint
#  user_id                  :bigint           not null
#
# Indexes
#
#  idx_tel_sip_profiles_account_agent_aor                  (account_id,agent_aor) UNIQUE WHERE (agent_aor IS NOT NULL)
#  idx_tel_sip_profiles_account_agent_ref                  (account_id,agent_ref) UNIQUE WHERE (agent_ref IS NOT NULL)
#  idx_tel_sip_profiles_account_inbox_user_ext             (account_id,inbox_id,user_id,internal_extension) UNIQUE
#  idx_tel_sip_profiles_account_provider_connection        (account_id,provider_connection_id)
#  index_telephony_sip_profiles_on_account_id              (account_id)
#  index_telephony_sip_profiles_on_inbox_id                (inbox_id)
#  index_telephony_sip_profiles_on_provider_connection_id  (provider_connection_id)
#  index_telephony_sip_profiles_on_user_id                 (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#  fk_rails_...  (provider_connection_id => telephony_provider_connections.id)
#  fk_rails_...  (user_id => users.id)
#
class Telephony::SipProfile < ApplicationRecord
  self.table_name = 'telephony_sip_profiles'

  AVAILABILITY_MODES = %w[browser_webphone external_extension provider_extension].freeze
  STATUSES = %w[draft active disabled deleting failed].freeze
  OWNERSHIP_STATUSES = %w[local managed legacy_reference read_only deleting].freeze
  MANAGED_BY_ONELINK = 'onelink'

  belongs_to :account, class_name: '::Account'
  belongs_to :inbox, class_name: '::Inbox', optional: true
  belongs_to :user, class_name: '::User'
  belongs_to :provider_connection, class_name: '::Telephony::ProviderConnection', optional: true, inverse_of: :sip_profiles

  validates :internal_extension, presence: true
  validates :availability_mode, presence: true, inclusion: { in: AVAILABILITY_MODES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :managed_by, presence: true
  validates :ownership_status, presence: true, inclusion: { in: OWNERSHIP_STATUSES }
  validates :internal_extension, uniqueness: { scope: %i[account_id inbox_id user_id] }
  validates :agent_ref, uniqueness: { scope: :account_id, allow_blank: true }
  validates :agent_aor, uniqueness: { scope: :account_id, allow_blank: true }
  validate :ensure_associations_belong_to_account

  before_validation :normalize_values

  scope :enabled, -> { where(enabled: true) }
  scope :recent, -> { order(updated_at: :desc, id: :desc) }
  scope :managed, -> { where(managed_by: MANAGED_BY_ONELINK, ownership_status: %w[local managed]) }

  def managed?
    managed_by == MANAGED_BY_ONELINK && ownership_status.in?(%w[local managed])
  end

  def read_only?
    !managed?
  end

  def to_telephony_h
    {
      id: id,
      inbox_id: inbox_id,
      user_id: user_id,
      user_name: user&.name,
      provider_connection_id: provider_connection_id,
      internal_extension: internal_extension,
      sip_username: sip_username,
      sip_password_configured: password_secret_ref.present?,
      sip_host: sip_host,
      agent_ref: agent_ref,
      agent_aor: agent_aor,
      fonoster_agent_ref: fonoster_agent_ref,
      credentials_ref: credentials_ref,
      fonoster_credentials_ref: fonoster_credentials_ref,
      enabled: enabled,
      availability_mode: availability_mode,
      status: status,
      registered_for_routing: registered_for_routing?,
      registration_state: metadata_value('registration_state', 'registrationState', 'registration', 'presence', 'status', 'state'),
      last_presence_source: metadata_value('last_presence_source'),
      last_presence_event_at: metadata_value('last_presence_event_at'),
      managed_by: managed_by,
      ownership_status: ownership_status,
      last_synced_at: last_synced_at,
      metadata: metadata
    }.compact
  end

  def update_browser_registration!(registered:, occurred_at: Time.current)
    registration_metadata = (metadata || {}).deep_dup
    registration_metadata['registration_state'] = registered ? 'registered' : 'offline'
    registration_metadata['presence'] = registered ? 'online' : 'offline'
    registration_metadata['registered'] = registered
    registration_metadata['available'] = registered
    registration_metadata['last_presence_source'] = 'browser_webphone'
    registration_metadata['last_presence_event_at'] = occurred_at.iso8601
    registration_metadata['last_unregistered_event_at'] = occurred_at.iso8601 unless registered

    update!(metadata: registration_metadata, last_synced_at: occurred_at)
  end

  DEFAULT_REGISTRATION_TTL = 5.minutes
  DEFAULT_REGISTRATION_STABILITY_WINDOW = 10.seconds

  def registered_for_routing?
    return false unless enabled?
    return false if status.in?(%w[disabled deleting failed])

    true
  end

  def browser_registered?
    return false unless availability_mode == 'browser_webphone'

    registered = if registration_state.blank?
                   truthy_metadata?('registered', 'online', 'available')
                 else
                   %w[registered online available reachable active].include?(registration_state.to_s.strip.downcase)
                 end

    registered && registration_fresh? && registration_stable?
  end

  private

  def normalize_values
    self.internal_extension = internal_extension.to_s.strip.presence
    self.sip_username = sip_username.to_s.strip.presence
    self.sip_host = sip_host.to_s.strip.downcase.presence
    self.agent_aor = agent_aor.to_s.strip.presence
    self.availability_mode = availability_mode.to_s.strip.downcase.presence || 'external_extension'
    self.status = status.to_s.strip.downcase.presence || 'draft'
    self.managed_by = managed_by.to_s.strip.presence || MANAGED_BY_ONELINK
    self.ownership_status = ownership_status.to_s.strip.downcase.presence || 'local'
    self.metadata = (metadata || {}).deep_stringify_keys
  end

  def ensure_associations_belong_to_account
    errors.add(:inbox, 'must belong to account') if inbox.present? && inbox.account_id != account_id
    errors.add(:user, 'must belong to account') if user.present? && !account.account_users.exists?(user_id: user_id)
    return if provider_connection.blank? || provider_connection.account_id == account_id

    errors.add(:provider_connection, 'must belong to account')
  end

  def registration_state
    metadata_value('registration_state', 'registrationState', 'registration', 'presence', 'status', 'state')
  end

  def registration_fresh?
    timestamp = registration_timestamp
    return false if timestamp.blank?

    timestamp >= registration_ttl.seconds.ago
  end

  def registration_stable?
    last_unregistered_at = parsed_metadata_time('last_unregistered_event_at', 'lastUnregisteredEventAt')
    return true if last_unregistered_at.blank?

    last_registered_at = registration_timestamp
    return true if last_registered_at.present? && last_unregistered_at <= last_registered_at

    last_unregistered_at < registration_stability_window.seconds.ago
  end

  def registration_timestamp
    parsed_metadata_time('last_presence_event_at', 'lastPresenceEventAt') || last_synced_at
  end

  def parsed_metadata_time(*keys)
    raw_timestamp = metadata_value(*keys)
    return if raw_timestamp.blank?
    return raw_timestamp.to_time if raw_timestamp.respond_to?(:to_time)

    Time.zone.parse(raw_timestamp.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def registration_ttl
    ENV.fetch('TELEPHONY_WEBPHONE_REGISTRATION_TTL_SECONDS', DEFAULT_REGISTRATION_TTL.to_i).to_i
  end

  def registration_stability_window
    ENV.fetch('TELEPHONY_WEBPHONE_REGISTRATION_STABILITY_SECONDS', DEFAULT_REGISTRATION_STABILITY_WINDOW.to_i).to_i
  end

  def metadata_value(*keys)
    source = metadata || {}
    keys.lazy.map { |key| source[key.to_s] || source[key.to_sym] }.find(&:present?)
  end

  def truthy_metadata?(*keys)
    keys.any? { |key| ActiveModel::Type::Boolean.new.cast(metadata_value(key)) }
  end
end
