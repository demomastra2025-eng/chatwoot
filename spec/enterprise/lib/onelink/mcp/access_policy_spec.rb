# frozen_string_literal: true

require 'rails_helper'

require Rails.root.join('enterprise/lib/onelink/mcp/access_policy').to_s

RSpec.describe Onelink::Mcp::AccessPolicy do
  let(:policy_config) do
    {
      'enabled' => true,
      'sources' => {
        'captain' => true,
        'openapi_read' => true,
        'openapi_write' => true
      },
      'max_risk_level' => 'custom'
    }
  end

  it 'treats allowed native tool ids as an exact allow-list' do
    policy = described_class.new(
      config: policy_config.merge('allowed_tool_ids' => ['get_workspace_profile'])
    )

    expect(
      policy.allows_captain_tool?(
        id: 'get_workspace_profile',
        group_name: 'Account',
        risk_level: 'high'
      )
    ).to be(true)
    expect(
      policy.allows_captain_tool?(
        id: 'update_workspace_profile',
        group_name: 'Account',
        risk_level: 'low'
      )
    ).to be(false)
  end

  it 'treats allowed OpenAPI operation ids as an exact allow-list' do
    policy = described_class.new(
      config: policy_config.merge('allowed_openapi_operation_ids' => ['listContacts'])
    )

    expect(
      policy.allows_openapi_operation?(
        operation_id: 'listContacts',
        method: 'GET',
        tag: 'Contacts',
        risk_level: 'high'
      )
    ).to be(true)
    expect(
      policy.allows_openapi_operation?(
        operation_id: 'deleteContact',
        method: 'DELETE',
        tag: 'Contacts',
        risk_level: 'low'
      )
    ).to be(false)
  end

  it 'falls back to source, group, and risk policy when exact allow-lists are empty' do
    policy = described_class.new(config: policy_config.merge('max_risk_level' => 'medium'))

    expect(
      policy.allows_captain_tool?(
        id: 'search_documentation',
        group_name: 'Knowledge',
        risk_level: 'medium'
      )
    ).to be(true)
    expect(
      policy.allows_captain_tool?(
        id: 'delete_campaign',
        group_name: 'Campaigns',
        risk_level: 'high'
      )
    ).to be(false)
  end

  it 'keeps MCP mutation confirmation mandatory even when legacy configs try to disable it' do
    policy = described_class.new(config: policy_config.merge('require_confirmation_for_mutations' => false))

    expect(policy.require_confirmation_for_mutations?).to be(true)
    expect(policy.mutation_confirmed?({})).to be(false)
    expect(policy.mutation_confirmed?('_confirm' => true)).to be(true)
  end
end
