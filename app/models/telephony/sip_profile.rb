# frozen_string_literal: true

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
      managed_by: managed_by,
      ownership_status: ownership_status,
      last_synced_at: last_synced_at,
      metadata: metadata
    }.compact
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
end
