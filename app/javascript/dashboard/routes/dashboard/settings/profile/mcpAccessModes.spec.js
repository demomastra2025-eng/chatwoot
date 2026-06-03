import {
  accessPolicyForMode,
  allowsToolForAccessMode,
  MCP_ACCESS_MODE_IDS,
  modeFromAccessPolicy,
} from './mcpAccessModes';

describe('mcpAccessModes', () => {
  it('builds the basic access policy without write API access', () => {
    expect(accessPolicyForMode(MCP_ACCESS_MODE_IDS.BASIC)).toEqual({
      enabled: true,
      sources: {
        captain: true,
        openapi_read: true,
        openapi_write: false,
      },
      max_risk_level: 'medium',
      require_confirmation_for_mutations: true,
      allowed_groups: [],
      blocked_groups: [],
      allowed_tool_ids: [],
      blocked_tool_ids: [],
      allowed_openapi_operation_ids: [],
      blocked_openapi_operation_ids: [],
    });
  });

  it('keeps the legacy medium id mapped to basic mode', () => {
    expect(accessPolicyForMode('medium')).toEqual(
      accessPolicyForMode(MCP_ACCESS_MODE_IDS.BASIC)
    );
  });

  it('builds the full access policy with write API access enabled', () => {
    expect(
      accessPolicyForMode(MCP_ACCESS_MODE_IDS.FULL, { enabled: false })
    ).toEqual({
      enabled: false,
      sources: {
        captain: true,
        openapi_read: true,
        openapi_write: true,
      },
      max_risk_level: 'custom',
      require_confirmation_for_mutations: true,
      allowed_groups: [],
      blocked_groups: [],
      allowed_tool_ids: [],
      blocked_tool_ids: [],
      allowed_openapi_operation_ids: [],
      blocked_openapi_operation_ids: [],
    });
  });

  it('detects full mode only when all workspace sources are enabled', () => {
    expect(
      modeFromAccessPolicy({
        sources: {
          captain: true,
          openapi_read: true,
          openapi_write: true,
        },
        max_risk_level: 'custom',
      })
    ).toBe(MCP_ACCESS_MODE_IDS.FULL);

    expect(
      modeFromAccessPolicy({
        sources: {
          captain: true,
          openapi_read: true,
          openapi_write: false,
        },
        max_risk_level: 'custom',
      })
    ).toBe(MCP_ACCESS_MODE_IDS.BASIC);
  });

  it('uses mode policy to classify tool preview visibility', () => {
    expect(
      allowsToolForAccessMode(
        { source: 'openapi_write', risk_level: 'medium' },
        MCP_ACCESS_MODE_IDS.BASIC
      )
    ).toBe(false);

    expect(
      allowsToolForAccessMode(
        { source: 'captain', risk_level: 'medium' },
        MCP_ACCESS_MODE_IDS.BASIC
      )
    ).toBe(true);

    expect(
      allowsToolForAccessMode(
        { source: 'openapi_write', risk_level: 'custom' },
        MCP_ACCESS_MODE_IDS.FULL
      )
    ).toBe(true);
  });
});
