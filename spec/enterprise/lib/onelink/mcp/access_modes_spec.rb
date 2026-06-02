# frozen_string_literal: true

require 'rails_helper'

require Rails.root.join('enterprise/lib/onelink/mcp/access_policy').to_s
require Rails.root.join('enterprise/lib/onelink/mcp/access_modes').to_s

RSpec.describe Onelink::Mcp::AccessModes do
  it 'builds the basic MCP preset from backend defaults' do
    expect(described_class.policy_for_mode(described_class::BASIC)).to include(
      'enabled' => true,
      'sources' => {
        'captain' => true,
        'openapi_read' => true,
        'openapi_write' => false
      },
      'max_risk_level' => 'medium',
      'require_confirmation_for_mutations' => true,
      'allowed_groups' => [],
      'blocked_groups' => []
    )
  end

  it 'builds the full MCP preset with all workspace sources enabled' do
    expect(described_class.policy_for_mode(described_class::FULL, enabled: false)).to include(
      'enabled' => false,
      'sources' => {
        'captain' => true,
        'openapi_read' => true,
        'openapi_write' => true
      },
      'max_risk_level' => 'custom',
      'require_confirmation_for_mutations' => false,
      'allowed_tool_ids' => [],
      'blocked_tool_ids' => []
    )
  end
end
