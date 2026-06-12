# frozen_string_literal: true

class Telephony::ProviderConnection < ApplicationRecord
  self.table_name = 'telephony_provider_connections'

  PROVIDER_KINDS = %w[asterisk_analog sipuni].freeze
  STATUSES = %w[draft active disabled deleting failed].freeze
  OWNERSHIP_STATUSES = %w[local managed legacy_reference read_only deleting].freeze
  MANAGED_BY_ONELINK = 'onelink'

  belongs_to :account, class_name: '::Account'
  belongs_to :created_by, class_name: '::User', optional: true
  belongs_to :updated_by, class_name: '::User', optional: true

  has_many :sip_profiles, class_name: '::Telephony::SipProfile', dependent: :nullify, inverse_of: :provider_connection
  has_many :number_bindings, class_name: '::Telephony::NumberBinding', dependent: :nullify, inverse_of: :provider_connection
  has_many :provisioning_runs, class_name: '::Telephony::ProvisioningRun', dependent: :nullify, inverse_of: :provider_connection

  validates :provider_kind, presence: true, inclusion: { in: PROVIDER_KINDS }
  validates :name, presence: true, uniqueness: { scope: %i[account_id provider_kind] }
  validates :transport, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :managed_by, presence: true
  validates :ownership_status, presence: true, inclusion: { in: OWNERSHIP_STATUSES }

  before_validation :normalize_values

  scope :recent, -> { order(updated_at: :desc, id: :desc) }
  scope :managed, -> { where(managed_by: MANAGED_BY_ONELINK, ownership_status: %w[local managed]) }

  def managed?
    managed_by == MANAGED_BY_ONELINK && ownership_status.in?(%w[local managed])
  end

  def read_only?
    !managed?
  end

  def to_virtual_pbx_h
    {
      id: id,
      provider_kind: provider_kind,
      name: name,
      host: host,
      port: port,
      transport: transport,
      username: username,
      send_register: send_register,
      status: status,
      managed_by: managed_by,
      ownership_status: ownership_status,
      fonoster_trunk_ref: fonoster_trunk_ref,
      credentials_ref: credentials_ref,
      password_configured: password_secret_ref.present?,
      fonoster_credentials_ref: fonoster_credentials_ref,
      fonoster_acl_ref: fonoster_acl_ref,
      last_synced_at: last_synced_at,
      provisioning_status: telephony_attribute(:provisioning_status),
      last_reconciled_at: telephony_attribute(:last_reconciled_at),
      remote_drift_detected_at: telephony_attribute(:remote_drift_detected_at),
      remote_drift_summary: telephony_attribute(:remote_drift_summary),
      metadata: metadata
    }.compact
  end

  def telephony_attribute(attr_name)
    return unless has_attribute?(attr_name)

    public_send(attr_name)
  end

  private

  def normalize_values
    self.provider_kind = provider_kind.to_s.tr('-', '_').strip.downcase.presence
    self.transport = transport.to_s.strip.downcase.presence || 'udp'
    self.status = status.to_s.strip.downcase.presence || 'draft'
    self.managed_by = managed_by.to_s.strip.presence || MANAGED_BY_ONELINK
    self.ownership_status = ownership_status.to_s.strip.downcase.presence || 'local'
    self.metadata = (metadata || {}).deep_stringify_keys
  end
end
