# frozen_string_literal: true

module Onelink::Mcp::AccessModes
  BASIC = 'basic'
  FULL = 'full'
  IDS = [BASIC, FULL].freeze

  module_function

  def policy_for_mode(mode, enabled: true)
    Onelink::Mcp::AccessPolicy.normalize(policy_config_for(normalize_mode(mode), enabled: enabled))
  end

  def normalize_mode(mode)
    normalized_mode = mode.to_s
    IDS.include?(normalized_mode) ? normalized_mode : BASIC
  end

  def policy_config_for(mode, enabled: true)
    return full_policy(enabled: enabled) if mode == FULL

    basic_policy(enabled: enabled)
  end

  def basic_policy(enabled: true)
    {
      'enabled' => enabled,
      'sources' => Onelink::Mcp::AccessPolicy::DEFAULT_SOURCES,
      'max_risk_level' => Onelink::Mcp::AccessPolicy::DEFAULT_MAX_RISK_LEVEL,
      'require_confirmation_for_mutations' => true
    }
  end

  def full_policy(enabled: true)
    {
      'enabled' => enabled,
      'sources' => Onelink::Mcp::AccessPolicy::DEFAULT_SOURCES.merge(
        Onelink::Mcp::AccessPolicy::SOURCE_OPENAPI_WRITE => true
      ),
      'max_risk_level' => 'custom',
      'require_confirmation_for_mutations' => false
    }
  end
end
