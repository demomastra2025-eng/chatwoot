# == Schema Information
#
# Table name: telephony_number_bindings
#
#  id             :bigint           not null, primary key
#  app_ref        :string
#  last_synced_at :datetime
#  metadata       :jsonb            not null
#  number_ref     :string           not null
#  phone_number   :string
#  provider       :string           default("fonoster"), not null
#  trunk_ref      :string
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint           not null
#  inbox_id       :bigint           not null
#
# Indexes
#
#  index_telephony_number_bindings_on_account_id          (account_id)
#  index_telephony_number_bindings_on_account_number_ref  (account_id,number_ref) UNIQUE
#  index_telephony_number_bindings_on_account_phone       (account_id,phone_number)
#  index_telephony_number_bindings_on_inbox_id            (inbox_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#
class Telephony::NumberBinding < ApplicationRecord
  self.table_name = 'telephony_number_bindings'

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
    fallback_mode
    fallback_message
  ].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :inbox, class_name: '::Inbox'

  has_one :routing_policy, class_name: '::Telephony::RoutingPolicy', dependent: :destroy
  has_many :call_sessions, class_name: '::Telephony::CallSession', dependent: :nullify

  validates :provider, presence: true
  validates :number_ref, presence: true, uniqueness: { scope: :account_id }
  validates :inbox_id, uniqueness: true

  scope :recent, -> { order(updated_at: :desc, id: :desc) }

  def self.sync_from_voice_channel!(voice_channel)
    return unless voice_channel&.provider == 'fonoster'
    return unless voice_channel.inbox.present?

    config = voice_channel.provider_config_hash.with_indifferent_access

    transaction do
      binding = find_or_initialize_by(inbox_id: voice_channel.inbox.id)
      binding.account = voice_channel.account
      binding.provider = voice_channel.provider
      binding.number_ref = config[:number_ref] || config[:fonoster_number_ref]
      binding.phone_number = voice_channel.phone_number
      binding.app_ref = config[:app_ref]
      binding.trunk_ref = config[:trunk_ref]
      binding.metadata = normalized_metadata(config)
      binding.last_synced_at = Time.current
      binding.save!

      policy = binding.routing_policy || binding.build_routing_policy(account: voice_channel.account)
      policy.assign_attributes(
        mode: config[:routing_mode].presence || policy.mode || 'operator',
        ai_enabled: normalized_ai_enabled(config, policy),
        ai_app_ref: config[:ai_app_ref],
        ai_deployment_mode: normalized_ai_deployment_mode(config, policy),
        fonoster_ai_app_ref: config[:fonoster_ai_app_ref],
        onelink_ai_app_ref: config[:onelink_ai_app_ref],
        fallback_ai_app_ref: config[:fallback_ai_app_ref],
        captain_assistant_id: config[:captain_assistant_id],
        ai_voice_settings: config[:ai_voice_settings].presence || policy.ai_voice_settings || {},
        operator_agent_ref: config[:operator_agent_ref],
        operator_agent_aor: config[:operator_agent_aor],
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

    if mode == 'operator' && sip_target?(operator_agent_aor)
      operator_fallback_payload(operator_agent_aor)
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

  def bridge_route_payload
    runtime_ref = runtime_app_ref
    return { mode: 'app', app_ref: runtime_ref } if runtime_ref.present?

    routing_policy&.bridge_payload || { mode: 'operator' }
  end

  def to_telephony_h
    {
      provider: provider,
      number_ref: number_ref,
      phone_number: phone_number,
      app_ref: configured_app_ref,
      effective_app_ref: app_ref_for_policy(routing_policy),
      trunk_ref: trunk_ref,
      last_synced_at: last_synced_at,
      routing_policy: routing_policy&.to_telephony_h
    }.compact
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

  def self.captain_ai_configured?(config)
    config[:captain_assistant_id].present? || config[:onelink_ai_app_ref].present?
  end
end
