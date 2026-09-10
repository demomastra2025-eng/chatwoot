class AccessControl::ModeAwareDecision
  EVENT_NAME = 'access_control.shadow_decision'.freeze

  def self.call(mode_resolution:, legacy_allowed:, access_role_allowed:)
    case mode_resolution.mode
    when 'enforced'
      access_role_allowed
    when 'shadow'
      instrument_shadow_decision(mode_resolution, legacy_allowed, access_role_allowed)
      legacy_allowed
    else
      legacy_allowed
    end
  end

  def self.instrument_shadow_scope(mode_resolution:, legacy_scope:)
    access_role_resolution = mode_resolution.access_role_resolution
    access_scope = access_role_resolution&.scope || 'none'
    publish_shadow_result(
      account_id: mode_resolution.account_id,
      account_user_id: access_role_resolution&.account_user_id,
      resource: access_role_resolution&.resource,
      capability: access_role_resolution&.capability,
      decision_kind: 'scope',
      legacy_scope: legacy_scope,
      access_scope: access_scope,
      matched: legacy_scope == access_scope
    )
  end

  def self.instrument_shadow_decision(mode_resolution, legacy_allowed, access_role_allowed)
    access_role_resolution = mode_resolution.access_role_resolution
    publish_shadow_result(
      account_id: mode_resolution.account_id,
      account_user_id: access_role_resolution&.account_user_id,
      resource: access_role_resolution&.resource,
      capability: access_role_resolution&.capability,
      decision_kind: 'record',
      access_scope: access_role_resolution&.scope || 'none',
      legacy_allowed: legacy_allowed,
      access_role_allowed: access_role_allowed,
      matched: legacy_allowed == access_role_allowed
    )
  end
  private_class_method :instrument_shadow_decision

  def self.publish_shadow_result(payload)
    ActiveSupport::Notifications.instrument(EVENT_NAME, payload)
    return if payload[:matched]

    Rails.logger.warn("[AccessControl::ShadowMismatch] #{payload.to_json}")
  end
  private_class_method :publish_shadow_result
end
