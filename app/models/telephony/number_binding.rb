# == Schema Information
#
# Table name: telephony_number_bindings
#
#  id                       :bigint           not null, primary key
#  app_ref                  :string
#  display_phone_number     :string
#  fonoster_tel_url         :string
#  ingress_number           :string
#  last_reconciled_at       :datetime
#  last_synced_at           :datetime
#  managed_by               :string
#  metadata                 :jsonb            not null
#  number_ref               :string           not null
#  ownership_status         :string           default("legacy_reference"), not null
#  phone_number             :string
#  provider                 :string           not null
#  provider_account_number  :string
#  provisioning_status      :string           default("local_only"), not null
#  remote_drift_detected_at :datetime
#  remote_drift_summary     :jsonb            not null
#  trunk_ref                :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  account_id               :bigint           not null
#  inbox_id                 :bigint           not null
#  provider_connection_id   :bigint
#
# Indexes
#
#  idx_tel_number_bindings_account_ingress                    (account_id,ingress_number)
#  idx_tel_number_bindings_account_ownership                  (account_id,ownership_status)
#  idx_tel_number_bindings_account_provider_connection        (account_id,provider_connection_id)
#  idx_tel_number_bindings_account_provisioning_status        (account_id,provisioning_status)
#  index_telephony_number_bindings_on_account_id              (account_id)
#  index_telephony_number_bindings_on_account_number_ref      (account_id,number_ref) UNIQUE
#  index_telephony_number_bindings_on_account_phone           (account_id,phone_number)
#  index_telephony_number_bindings_on_inbox_id                (inbox_id) UNIQUE
#  index_telephony_number_bindings_on_provider_connection_id  (provider_connection_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#  fk_rails_...  (provider_connection_id => telephony_provider_connections.id)
#
class Telephony::NumberBinding < ApplicationRecord
  self.table_name = 'telephony_number_bindings'

  MANAGED_BY_ONELINK = 'onelink'
  MANAGED_OWNERSHIP_STATUSES = %w[local managed].freeze
  PROVIDER_OWNED_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze

  KNOWN_PROVIDER_CONFIG_KEYS = %w[
    number_ref
    fonoster_number_ref
    app_ref
    trunk_ref
    runtime_app_ref
    app_route_app_ref
    target_app_ref
    routing_mode
    ai_enabled
    ai_app_ref
    ai_deployment_mode
    fonoster_ai_app_ref
    onelink_ai_app_ref
    fallback_ai_app_ref
    captain_assistant_id
    ai_voice_settings
    operator_agent_ref
    operator_agent_aor
    operator_distribution_mode
    fallback_mode
    fallback_message
    display_phone_number
    provider_account_number
    ingress_number
    fonoster_tel_url
    provider_connection_id
    managed_by
    ownership_status
  ].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :inbox, class_name: '::Inbox'
  belongs_to :provider_connection, class_name: '::Telephony::ProviderConnection', optional: true, inverse_of: :number_bindings

  has_one :routing_policy, class_name: '::Telephony::RoutingPolicy', dependent: :destroy
  has_many :call_sessions, class_name: '::Telephony::CallSession', dependent: :nullify
  has_many :provisioning_runs, class_name: '::Telephony::ProvisioningRun', dependent: :nullify, inverse_of: :number_binding
  has_many :sip_profiles, through: :inbox, source: :telephony_sip_profiles

  validates :provider, presence: true
  validates :number_ref, presence: true, uniqueness: { scope: :account_id }
  validates :inbox_id, uniqueness: true
  validate :provider_connection_belongs_to_account

  scope :recent, -> { order(updated_at: :desc, id: :desc) }
  scope :managed, -> { where(managed_by: MANAGED_BY_ONELINK, ownership_status: MANAGED_OWNERSHIP_STATUSES) }

  def self.sync_from_voice_channel!(voice_channel)
    return unless voice_channel&.provider.in?(PROVIDER_OWNED_SIP_PROVIDERS)
    return unless voice_channel.inbox.present?

    config = voice_channel.provider_config_hash.with_indifferent_access

    transaction do
      binding = find_or_initialize_by(inbox_id: voice_channel.inbox.id)
      phone_fields = phone_fields_from_config(config, voice_channel)
      binding.account = voice_channel.account
      binding.provider = voice_channel.provider
      binding.number_ref = config[:number_ref]
      binding.phone_number = phone_fields[:ingress_number] || voice_channel.phone_number
      binding.display_phone_number = phone_fields[:display_phone_number]
      binding.provider_account_number = phone_fields[:provider_account_number]
      binding.ingress_number = phone_fields[:ingress_number]
      binding.fonoster_tel_url = nil
      binding.app_ref = nil
      binding.trunk_ref = nil
      binding.managed_by = config[:managed_by]
      binding.ownership_status = config[:ownership_status].presence || binding.ownership_status || 'legacy_reference'
      binding.metadata = normalized_metadata(config)
      binding.last_synced_at = Time.current
      binding.save!

      policy = binding.routing_policy || binding.build_routing_policy(account: voice_channel.account)
      policy.assign_attributes(
        mode: config[:routing_mode].presence || policy.mode || 'operator',
        ai_enabled: normalized_ai_enabled(config, policy),
        ai_app_ref: config[:ai_app_ref],
        ai_deployment_mode: normalized_ai_deployment_mode(config, policy),
        fonoster_ai_app_ref: nil,
        onelink_ai_app_ref: config[:onelink_ai_app_ref],
        fallback_ai_app_ref: config[:fallback_ai_app_ref],
        captain_assistant_id: config[:captain_assistant_id],
        ai_voice_settings: config[:ai_voice_settings].presence || policy.ai_voice_settings || {},
        operator_agent_ref: config[:operator_agent_ref],
        operator_agent_aor: config[:operator_agent_aor],
        settings: policy.settings.to_h.merge(
          'operator_distribution_mode' => synced_operator_distribution_mode(config, policy)
        ),
        fallback_mode: config[:fallback_mode].presence || policy.fallback_mode || 'reject',
        fallback_message: config[:fallback_message]
      )
      policy.save!

      binding
    end
  end

  def voice_channel
    inbox&.channel
  end

  def configured_app_ref
    config = voice_channel&.provider_config_hash&.with_indifferent_access
    config&.dig(:app_route_app_ref).presence || config&.dig(:target_app_ref).presence || config&.dig(:app_ref).presence || self[:app_ref]
  rescue JSON::ParserError, TypeError
    self[:app_ref]
  end

  def runtime_app_ref
    config = voice_channel&.provider_config_hash&.with_indifferent_access
    config&.dig(:runtime_app_ref).presence || self[:app_ref].presence || config&.dig(:app_ref).presence
  rescue JSON::ParserError, TypeError
    self[:app_ref]
  end

  def effective_app_ref(policy = routing_policy)
    return configured_app_ref unless policy&.mode.to_s == 'ai'

    policy.effective_ai_app_ref.presence || configured_app_ref
  end

  def bridge_fallback_route(policy = routing_policy)
    mode = policy&.mode.to_s
    operator_agent_aor = policy&.resolved_operator_agent_aor

    if mode == 'operator' && policy&.targeted_operator_distribution? && sip_target?(operator_agent_aor)
      operator_fallback_payload(operator_agent_aor)
    elsif mode == 'operator'
      { fallback_mode: 'operator' }
    elsif configured_app_ref.present?
      {
        fallback_mode: 'app',
        fallback_app_ref: configured_app_ref
      }
    else
      {
        fallback_mode: 'clear'
      }
    end
  end

  def operator_fallback_payload(operator_target)
    return { fallback_mode: 'clear' } unless sip_target?(operator_target)

    { fallback_mode: 'operator', fallback_agent_aor: operator_target }
  end

  def sip_target?(target)
    target.to_s.downcase.start_with?('sip:')
  end

  def app_ref_for_policy(policy = routing_policy)
    policy&.mode.to_s == 'ai' ? effective_app_ref(policy) : configured_app_ref
  end

  def routing_mode
    routing_policy&.mode || 'operator'
  end

  def managed?
    managed_by == MANAGED_BY_ONELINK && ownership_status.in?(MANAGED_OWNERSHIP_STATUSES)
  end

  def read_only?
    !managed?
  end

  def effective_display_phone_number
    display_phone_number.presence || voice_channel&.phone_number || phone_number
  end

  def effective_provider_account_number
    provider_account_number.presence || metadata_value('provider_account_number', 'account_number') || ingress_number.presence || phone_number
  end

  def effective_ingress_number
    ingress_number.presence || metadata_value('ingress_number') || phone_number
  end

  def phone_split_allowed?
    effective_display_phone_number.present? &&
      effective_ingress_number.present? &&
      effective_display_phone_number != effective_ingress_number
  end

  def bridge_route_payload
    runtime_ref = runtime_app_ref
    return { mode: 'app', app_ref: runtime_ref } if runtime_ref.present?

    routing_policy&.bridge_payload || { mode: 'operator' }
  end

  def to_telephony_h
    payload = {
      provider: provider,
      number_ref: number_ref,
      phone_number: phone_number,
      display_phone_number: effective_display_phone_number,
      provider_account_number: effective_provider_account_number,
      ingress_number: effective_ingress_number,
      app_ref: provider_owned_sip_provider?(provider) ? nil : configured_app_ref,
      effective_app_ref: provider_owned_sip_provider?(provider) ? nil : app_ref_for_policy(routing_policy),
      trunk_ref: provider_owned_sip_provider?(provider) ? nil : trunk_ref,
      provider_connection_id: provider_connection_id,
      managed_by: managed_by,
      ownership_status: ownership_status,
      last_synced_at: last_synced_at,
      routing_policy: routing_policy&.to_telephony_h
    }
    payload.compact
  end

  def provider_owned_sip_provider?(provider)
    self.class.provider_owned_sip_provider?(provider)
  end

  def self.provider_owned_sip_provider?(provider)
    provider.to_s.in?(PROVIDER_OWNED_SIP_PROVIDERS)
  end

  def self.phone_fields_from_config(config, voice_channel)
    display_phone_number = first_present(config[:display_phone_number], voice_channel.phone_number)
    provider_account_number = first_present(
      config[:provider_account_number],
      config[:sipuni_account_number],
      config[:binotel_account_number],
      config[:account_number]
    )
    ingress_tel_url = first_present(config[:tel_url], config[:fonoster_tel_url])
    ingress_number = first_present(
      config[:ingress_number],
      config[:sipuni_ingress_number],
      config[:binotel_ingress_number],
      tel_url_number(ingress_tel_url),
      provider_account_number,
      display_phone_number
    )

    {
      display_phone_number: display_phone_number,
      provider_account_number: provider_account_number,
      ingress_number: ingress_number
    }
  end

  def self.normalized_metadata(config)
    config.except(*KNOWN_PROVIDER_CONFIG_KEYS).compact
  end

  def self.normalized_ai_enabled(config, policy)
    return ActiveModel::Type::Boolean.new.cast(config[:ai_enabled]) if config.key?(:ai_enabled)
    return true if captain_ai_configured?(config)

    policy.ai_enabled?
  end

  def self.normalized_ai_deployment_mode(config, policy)
    return config[:ai_deployment_mode] if config[:ai_deployment_mode].present?
    return Telephony::RoutingPolicy::AI_DEPLOYMENT_ONELINK_MANAGED if captain_ai_configured?(config)

    policy.ai_deployment_mode
  end

  def self.synced_operator_distribution_mode(config, policy)
    if config.key?(:operator_distribution_mode)
      return Telephony::RoutingPolicy.normalized_operator_distribution_mode(config[:operator_distribution_mode])
    end

    policy.operator_distribution_mode
  end

  def self.captain_ai_configured?(config)
    config[:captain_assistant_id].present? || config[:onelink_ai_app_ref].present?
  end

  def self.first_present(*values)
    values.find(&:present?)
  end

  def self.tel_url_number(value)
    value.to_s.sub(/\Atel:/i, '').presence
  end

  def self.tel_url_for(value)
    value.present? ? "tel:#{value}" : nil
  end

  private

  def metadata_value(*keys)
    source = (metadata || {}).with_indifferent_access
    keys.lazy.map { |key| source[key] }.find(&:present?)
  end

  def tel_url_for(value)
    self.class.tel_url_for(value)
  end

  def provider_connection_belongs_to_account
    return if provider_connection.blank? || provider_connection.account_id == account_id

    errors.add(:provider_connection, 'must belong to account')
  end
end
