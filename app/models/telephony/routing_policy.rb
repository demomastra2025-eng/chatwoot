# == Schema Information
#
# Table name: telephony_routing_policies
#
#  id                 :bigint           not null, primary key
#  ai_app_ref         :string
#  ai_enabled         :boolean          default(FALSE), not null
#  business_hours     :jsonb            not null
#  fallback_message   :text
#  fallback_mode      :string           default("reject"), not null
#  mode               :string           default("operator"), not null
#  operator_agent_aor :string
#  operator_agent_ref :string
#  settings           :jsonb            not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  account_id         :bigint           not null
#  number_binding_id  :bigint           not null
#
# Indexes
#
#  index_telephony_routing_policies_on_account_id         (account_id)
#  index_telephony_routing_policies_on_account_mode       (account_id,mode)
#  index_telephony_routing_policies_on_number_binding_id  (number_binding_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (number_binding_id => telephony_number_bindings.id)
#
class Telephony::RoutingPolicy < ApplicationRecord
  self.table_name = 'telephony_routing_policies'

  VALID_MODES = %w[operator app ai reject voicemail ivr].freeze
  VALID_FALLBACK_MODES = %w[reject operator app voicemail].freeze
  BRIDGE_SUPPORTED_MODES = %w[operator app ai reject].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :number_binding, class_name: '::Telephony::NumberBinding'

  validates :mode, presence: true, inclusion: { in: VALID_MODES }
  validates :fallback_mode, presence: true, inclusion: { in: VALID_FALLBACK_MODES }
  validate :validate_ai_app_ref
  validate :validate_app_mode_configuration
  validate :validate_operator_mode_configuration

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

  def to_telephony_h
    {
      mode: mode,
      ai_enabled: ai_enabled,
      ai_app_ref: ai_app_ref,
      operator_agent_ref: operator_agent_ref,
      operator_agent_aor: operator_agent_aor,
      fallback_mode: fallback_mode,
      fallback_message: fallback_message,
      business_hours: business_hours,
      settings: settings
    }.compact
  end

  private

  def bridge_payload_options
    case bridge_mode
    when 'ai'
      { app_ref: ai_app_ref }
    when 'app'
      { app_ref: number_binding&.configured_app_ref }
    when 'operator'
      { agent_aor: resolved_operator_agent_aor }
    when 'reject'
      { message: fallback_message }
    else
      {}
    end
  end

  def normalize_values
    self.mode = mode.to_s.strip.downcase.presence || 'operator'
    self.fallback_mode = fallback_mode.to_s.strip.downcase.presence || 'reject'
    self.ai_enabled = ai_mode?
  end

  def validate_ai_app_ref
    return unless ai_mode? && ai_app_ref.blank?

    errors.add(:ai_app_ref, 'is required when mode is ai')
  end

  def validate_app_mode_configuration
    return unless app_mode?
    return if number_binding&.configured_app_ref.present?

    errors.add(:mode, 'app routing requires a configured primary app ref')
  end

  def validate_operator_mode_configuration
    return unless operator_mode?
    return if resolved_operator_agent_aor.present?

    errors.add(:mode, 'operator routing requires a configured operator agent')
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
end
