import {
  buildAgentRoleAssignment,
  buildAgentRoleOptions,
  getAccessRoleDisplayName,
  initialAgentRoleOptionId,
  isAgentAssignmentCatalogReady,
} from './agentRoleOptions';

const t = key => key;
const customRoles = [{ id: 7, name: 'Legacy support' }];
const canonicalRecords = [
  { id: 10, name: 'Employee', system_key: 'employee' },
  { id: 11, name: 'Observer', system_key: 'observer' },
  { id: 12, name: 'Clinic support', system_key: null },
];

const catalog = (overrides = {}) => ({
  records: canonicalRecords,
  assignmentsEnabled: false,
  loaded: true,
  error: false,
  ...overrides,
});

describe('agentRoleOptions', () => {
  it('builds the legacy options when normalized assignments are not advertised', () => {
    expect(
      buildAgentRoleOptions({ catalog: catalog(), customRoles, t })
    ).toEqual([
      expect.objectContaining({
        id: 'legacy:administrator',
        role: 'administrator',
      }),
      expect.objectContaining({ id: 'legacy:agent', role: 'agent' }),
      expect.objectContaining({ id: 'legacy-custom:7', customRoleId: 7 }),
    ]);
  });

  it('builds only canonical options when normalized assignments are advertised', () => {
    const options = buildAgentRoleOptions({
      catalog: catalog({ assignmentsEnabled: true }),
      customRoles,
      t,
    });

    expect(options).toHaveLength(3);
    expect(options).toContainEqual(
      expect.objectContaining({ id: 'access:11', accessRoleId: 11 })
    );
    expect(options.map(option => option.id)).not.toContain('legacy-custom:7');
  });

  it('serializes canonical create and update assignments', () => {
    const option = { mode: 'canonical', accessRoleId: 11 };

    expect(buildAgentRoleAssignment({ option })).toEqual({
      access_role_id: 11,
    });
    expect(
      buildAgentRoleAssignment({ option, previousAccessRoleId: 10 })
    ).toEqual({
      access_role_id: 11,
      previous_access_role_id: 10,
    });
  });

  it('serializes legacy system and custom assignments', () => {
    expect(
      buildAgentRoleAssignment({ option: { mode: 'legacy', role: 'agent' } })
    ).toEqual({ role: 'agent', custom_role_id: null });
    expect(
      buildAgentRoleAssignment({
        option: { mode: 'legacy', customRoleId: 7 },
      })
    ).toEqual({ custom_role_id: 7 });
  });

  it('hydrates edit selection from the active assignment mode', () => {
    expect(
      initialAgentRoleOptionId({
        catalog: catalog({ assignmentsEnabled: true }),
        accessRoleId: 11,
        customRoleId: 7,
        role: 'agent',
      })
    ).toBe('access:11');
    expect(
      initialAgentRoleOptionId({
        catalog: catalog(),
        accessRoleId: 11,
        customRoleId: 7,
        role: 'agent',
      })
    ).toBe('legacy-custom:7');
  });

  it('uses localized system names and canonical custom names for display', () => {
    const canonicalCatalog = catalog({ assignmentsEnabled: true });

    expect(
      getAccessRoleDisplayName({
        catalog: canonicalCatalog,
        accessRoleId: 11,
        t,
      })
    ).toBe('CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.OBSERVER');
    expect(
      getAccessRoleDisplayName({
        catalog: canonicalCatalog,
        accessRoleId: 12,
        t,
      })
    ).toBe('Clinic support');
  });

  it('waits for the catalog request and enables legacy fallback after an error', () => {
    expect(
      isAgentAssignmentCatalogReady({
        catalog: catalog({ loaded: false }),
        isFetching: true,
      })
    ).toBe(false);
    expect(
      isAgentAssignmentCatalogReady({
        catalog: catalog({ loaded: false, error: true }),
        isFetching: false,
      })
    ).toBe(true);
  });
});
