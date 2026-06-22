# == Schema Information
#
# Table name: telephony_routing_policies
#
#  id                   :bigint           not null, primary key
#  ai_app_ref           :string
#  ai_deployment_mode   :string           default("fonoster_managed"), not null
#  ai_enabled           :boolean          default(FALSE), not null
#  ai_voice_settings    :jsonb            not null
#  business_hours       :jsonb            not null
#  fallback_ai_app_ref  :string
#  fallback_message     :text
#  fallback_mode        :string           default("reject"), not null
#  fonoster_ai_app_ref  :string
#  mode                 :string           default("operator"), not null
#  onelink_ai_app_ref   :string
#  operator_agent_aor   :string
#  operator_agent_ref   :string
#  settings             :jsonb            not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#  captain_assistant_id :bigint
#  number_binding_id    :bigint           not null
#
# Indexes
#
#  index_telephony_routing_policies_on_account_ai_deployment  (account_id,ai_deployment_mode)
#  index_telephony_routing_policies_on_account_id             (account_id)
#  index_telephony_routing_policies_on_account_mode           (account_id,mode)
#  index_telephony_routing_policies_on_captain_assistant_id   (captain_assistant_id)
#  index_telephony_routing_policies_on_number_binding_id      (number_binding_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (captain_assistant_id => captain_assistants.id)
#  fk_rails_...  (number_binding_id => telephony_number_bindings.id)
#
class Telephony::RoutingPolicy < ApplicationRecord
  self.table_name = 'telephony_routing_policies'

  CURRENT_FONOSTER_OPERATOR_AGENT_AOR = 'sip:1001@operator.cloud.vconsult.kz'.freeze
  STALE_FONOSTER_OPERATOR_AGENT_AORS = ['sip:1001@company.example'].freeze

  VALID_MODES = %w[operator app ai reject voicemail ivr].freeze
  VALID_FALLBACK_MODES = %w[reject operator app ai voicemail].freeze
  BRIDGE_SUPPORTED_MODES = %w[operator app ai reject].freeze
  OPERATOR_DISTRIBUTION_BROADCAST = 'broadcast'.freeze
  OPERATOR_DISTRIBUTION_TARGETED = 'targeted'.freeze
  VALID_OPERATOR_DISTRIBUTION_MODES = [
    OPERATOR_DISTRIBUTION_BROADCAST,
    OPERATOR_DISTRIBUTION_TARGETED
  ].freeze
  AI_DEPLOYMENT_FONOSTER_MANAGED = 'fonoster_managed'.freeze
  AI_DEPLOYMENT_ONELINK_MANAGED = 'onelink_managed'.freeze
  AI_DEPLOYMENT_MODES = [AI_DEPLOYMENT_FONOSTER_MANAGED, AI_DEPLOYMENT_ONELINK_MANAGED].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :number_binding, class_name: '::Telephony::NumberBinding'
  belongs_to :captain_assistant, class_name: '::Captain::Assistant', optional: true

  validates :mode, presence: true, inclusion: { in: VALID_MODES }
  validates :fallback_mode, presence: true, inclusion: { in: VALID_FALLBACK_MODES }
  validates :ai_deployment_mode, presence: true, inclusion: { in: AI_DEPLOYMENT_MODES }
  validate :validate_ai_app_ref
  validate :validate_app_mode_configuration
  validate :validate_operator_mode_configuration
  validate :validate_ai_fallback_configuration
  validate :validate_operator_agent_aor
  validate :validate_captain_assistant_account

  before_validation :normalize_values

  def ai_mode?
    mode == 'ai'
  end

  def app_mode?
    mode == 'app'
  end

  def operator_mode?
    mode == 'operator'
  end

  def operator_distribution_mode
    self.class.normalized_operator_distribution_mode(settings.to_h['operator_distribution_mode'])
  end

  def targeted_operator_distribution?
    operator_distribution_mode == OPERATOR_DISTRIBUTION_TARGETED
  end

  def bridge_payload
    { mode: bridge_mode }.merge(bridge_payload_options).compact
  end

  def bridge_mode
    BRIDGE_SUPPORTED_MODES.include?(mode) ? mode : 'reject'
  end

  def resolved_operator_agent_aor
    if operator_agent_ref.present?
      resolved_operator_binding&.agent_aor.presence || operator_agent_aor.presence
    else
      operator_agent_aor.presence || resolved_operator_binding&.agent_aor
    end
  end

  def operator_target_payload
    return {} unless targeted_operator_distribution?

    target = resolved_operator_agent_aor
    return {} if target.blank? || !sip_target?(target)

    { agent_aor: target }
  end

  def effective_ai_app_ref
    ai_app_ref_candidates.detect(&:present?)
  end

  def ai_app_ref_candidates
    if ai_deployment_mode == AI_DEPLOYMENT_ONELINK_MANAGED
      [onelink_ai_app_ref, ai_app_ref, fonoster_ai_app_ref, fallback_ai_app_ref, ENV.fetch('ONELINK_AI_VOICE_APP_REF', nil)]
    else
      [fonoster_ai_app_ref, ai_app_ref, fallback_ai_app_ref]
    end
  end

  def to_telephony_h
    {
      mode: mode,
      ai_enabled: ai_enabled,
      ai_app_ref: ai_app_ref,
      ai_deployment_mode: ai_deployment_mode,
      fonoster_ai_app_ref: fonoster_ai_app_ref,
      onelink_ai_app_ref: onelink_ai_app_ref,
      fallback_ai_app_ref: fallback_ai_app_ref,
      effective_ai_app_ref: effective_ai_app_ref,
      captain_assistant_id: captain_assistant_id,
      ai_voice_settings: ai_voice_settings,
      operator_agent_ref: operator_agent_ref,
      operator_agent_aor: operator_agent_aor,
      operator_distribution_mode: operator_distribution_mode,
      fallback_mode: fallback_mode,
      fallback_message: fallback_message,
      business_hours: business_hours,
      settings: settings
    }.compact
  end

  def self.normalized_operator_distribution_mode(value)
    candidate = value.to_s.strip.downcase.presence
    return candidate if VALID_OPERATOR_DISTRIBUTION_MODES.include?(candidate)

    OPERATOR_DISTRIBUTION_BROADCAST
  end

  private

  def bridge_payload_options
    case bridge_mode
    when 'ai'
      { app_ref: effective_ai_app_ref }
    when 'app'
      { app_ref: number_binding&.configured_app_ref }
    when 'operator'
      operator_target_payload
    when 'reject'
      { message: fallback_message }
    else
      {}
    end
  end

  def normalize_values
    normalize_mode_fields
    normalize_ai_configuration
    normalize_operator_distribution_settings
    self.operator_agent_aor = normalize_operator_agent_aor(operator_agent_aor)
  end

  def normalize_mode_fields
    self.mode = mode.to_s.strip.downcase.presence || 'operator'
    self.fallback_mode = fallback_mode.to_s.strip.downcase.presence || 'reject'
  end

  def normalize_ai_configuration
    self.ai_deployment_mode = ai_deployment_mode.to_s.strip.downcase.presence || AI_DEPLOYMENT_FONOSTER_MANAGED
    self.ai_enabled = explicit_ai_enabled? || ai_mode? || fallback_mode == 'ai'
    self.ai_voice_settings = (ai_voice_settings || {}).deep_stringify_keys
  end

  def normalize_operator_distribution_settings
    normalized_settings = (settings || {}).deep_stringify_keys
    normalized_settings['operator_distribution_mode'] = self.class.normalized_operator_distribution_mode(
      normalized_settings['operator_distribution_mode']
    )
    self.settings = normalized_settings
  end

  def normalize_operator_agent_aor(value)
    candidate = value.to_s.strip.presence
    return if candidate.blank?
    return CURRENT_FONOSTER_OPERATOR_AGENT_AOR if STALE_FONOSTER_OPERATOR_AGENT_AORS.include?(candidate)

    candidate
  end

  def validate_ai_app_ref
    return unless ai_mode? && effective_ai_app_ref.blank?

    errors.add(:ai_app_ref, 'is required when mode is ai')
  end

  def validate_app_mode_configuration
    return unless app_mode?
    return if number_binding&.configured_app_ref.present?

    errors.add(:mode, 'app routing requires a configured primary app ref')
  end

  def validate_operator_mode_configuration
    return unless operator_mode?
    return unless targeted_operator_distribution?
    return if sip_target?(resolved_operator_agent_aor)

    errors.add(:mode, 'operator routing requires a configured operator agent')
  end

  def validate_operator_agent_aor
    return if operator_agent_aor.blank? || sip_target?(operator_agent_aor)

    errors.add(:operator_agent_aor, 'must be a SIP AOR')
  end

  def validate_ai_fallback_configuration
    return unless fallback_mode == 'ai'
    return if effective_ai_app_ref.present?

    errors.add(:fallback_mode, 'ai fallback requires ai_app_ref')
  end

  def validate_captain_assistant_account
    return if captain_assistant_id.blank?
    return if captain_assistant&.account_id == account_id

    errors.add(:captain_assistant_id, 'must belong to the routing policy account')
  end

  def resolved_operator_binding
    scope = account&.telephony_agent_bindings
    return if scope.blank?

    if operator_agent_ref.present?
      scope.find_by(agent_ref: operator_agent_ref)
    elsif operator_agent_aor.present?
      scope.find_by(agent_aor: operator_agent_aor)
    end
  end

  def sip_target?(target)
    target.to_s.downcase.start_with?('sip:')
  end

  def explicit_ai_enabled?
    ActiveModel::Type::Boolean.new.cast(ai_enabled)
  end
end
