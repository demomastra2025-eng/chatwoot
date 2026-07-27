# frozen_string_literal: true

# == Schema Information
#
# Table name: telephony_provider_connections
#
#  id                       :bigint           not null, primary key
#  credentials_ref          :string
#  fonoster_acl_ref         :string
#  fonoster_credentials_ref :string
#  fonoster_trunk_ref       :string
#  host                     :string
#  last_reconciled_at       :datetime
#  last_synced_at           :datetime
#  managed_by               :string           default("onelink"), not null
#  metadata                 :jsonb            not null
#  name                     :string           not null
#  ownership_status         :string           default("local"), not null
#  password_secret_ref      :string
#  port                     :integer
#  provider_kind            :string           not null
#  provisioning_status      :string           default("local_only"), not null
#  remote_drift_detected_at :datetime
#  remote_drift_summary     :jsonb            not null
#  send_register            :boolean          default(FALSE), not null
#  status                   :string           default("draft"), not null
#  transport                :string           default("udp"), not null
#  username                 :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  account_id               :bigint           not null
#  created_by_id            :bigint
#  updated_by_id            :bigint
#
# Indexes
#
#  idx_tel_provider_connections_account_kind_name            (account_id,provider_kind,name) UNIQUE
#  idx_tel_provider_connections_account_provisioning_status  (account_id,provisioning_status)
#  idx_tel_provider_connections_account_status               (account_id,status)
#  idx_tel_provider_connections_account_trunk_ref            (account_id,fonoster_trunk_ref) UNIQUE WHERE (fonoster_trunk_ref IS NOT NULL)
#  index_telephony_provider_connections_on_account_id        (account_id)
#  index_telephony_provider_connections_on_created_by_id     (created_by_id)
#  index_telephony_provider_connections_on_updated_by_id     (updated_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (created_by_id => users.id)
#  fk_rails_...  (updated_by_id => users.id)
#
class Telephony::ProviderConnection < ApplicationRecord
  self.table_name = 'telephony_provider_connections'

  PROVIDER_KINDS = %w[asterisk_analog sipuni binotel beeline].freeze
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
    payload = {
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
      credentials_ref: credentials_ref,
      password_configured: password_secret_ref.present?,
      last_synced_at: last_synced_at,
      provisioning_status: telephony_attribute(:provisioning_status),
      last_reconciled_at: telephony_attribute(:last_reconciled_at),
      remote_drift_detected_at: telephony_attribute(:remote_drift_detected_at),
      remote_drift_summary: telephony_attribute(:remote_drift_summary),
      metadata: metadata
    }
    payload.compact
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
