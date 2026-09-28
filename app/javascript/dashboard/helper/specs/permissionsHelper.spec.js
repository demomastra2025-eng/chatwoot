import {
  getCurrentAccount,
  getUserPermissions,
  hasCrmManagePermission,
  hasCrmViewPermission,
  hasPermissions,
  filterItemsByPermission,
} from '../permissionsHelper';
import {
  CONTACT_ACCESS_PERMISSIONS,
  CONTACT_PERMISSIONS,
  CONVERSATION_ACCESS_PERMISSIONS,
  CONVERSATION_PERMISSIONS,
  CRM_DEAL_MANAGE_PERMISSION,
  CRM_DEAL_MANAGE_PERMISSIONS,
  CRM_DEAL_VIEW_PERMISSION,
  CRM_DEAL_VIEW_PERMISSIONS,
  CRM_TASK_MANAGE_PERMISSION,
  CRM_TASK_MANAGE_PERMISSIONS,
  CRM_TASK_VIEW_PERMISSION,
  CRM_TASK_VIEW_PERMISSIONS,
  CRM_SETTINGS_MANAGE_PERMISSION,
  CRM_SETTINGS_VIEW_PERMISSION,
  ROLES,
  SCHEDULING_ACCESS_PERMISSIONS,
} from '../../constants/permissions';

describe('#getCurrentAccount', () => {
  it('should return the current account', () => {
    expect(getCurrentAccount({ accounts: [{ id: 1 }] }, 1)).toEqual({ id: 1 });
    expect(getCurrentAccount({ accounts: [] }, 1)).toEqual(undefined);
  });
});

describe('#getUserPermissions', () => {
  it('should return the correct permissions', () => {
    const user = {
      accounts: [
        { id: 1, permissions: ['conversations_manage'] },
        { id: 3, permissions: ['contacts_manage'] },
      ],
    };
    expect(getUserPermissions(user, 1)).toEqual(['conversations_manage']);
    expect(getUserPermissions(user, '3')).toEqual(['contacts_manage']);
    expect(getUserPermissions(user, 2)).toEqual([]);
  });
});

describe('CRM access in the active account', () => {
  const dealCapabilities = [
    'view',
    'create',
    'update_fields',
    'assign',
    'transition',
    'delete_archive',
  ];
  const taskCapabilities = [...dealCapabilities, 'complete_cancel'];
  const membership = (id, overrides = {}) => ({
    id,
    access_control_mode: 'enforced',
    permissions: ['agent'],
    crm_capabilities: { deals: dealCapabilities, tasks: taskCapabilities },
    crm_grant_scopes: {
      deals: Object.fromEntries(
        dealCapabilities.map(capability => [capability, 'all'])
      ),
      tasks: Object.fromEntries(
        taskCapabilities.map(capability => [capability, 'all'])
      ),
    },
    crm_team_ids: [],
    ...overrides,
  });

  it('keeps Observer read-only despite a legacy agent token', () => {
    const user = {
      accounts: [
        membership(1, {
          crm_capabilities: { deals: ['view'], tasks: ['view'] },
          crm_grant_scopes: { deals: { view: 'all' }, tasks: { view: 'all' } },
        }),
      ],
    };
    expect(hasCrmViewPermission(user, 1, 'deals')).toBe(true);
    expect(hasCrmViewPermission(user, 1, 'tasks')).toBe(true);
    expect(hasCrmManagePermission(user, 1, 'deals')).toBe(false);
    expect(hasCrmManagePermission(user, 1, 'tasks', 'create')).toBe(false);
  });

  it('enables Employee, Department Lead and Administrator from grants, not their label', () => {
    [['agent'], ['agent'], ['administrator']].forEach(permissions => {
      const user = { accounts: [membership(1, { permissions })] };
      expect(hasCrmManagePermission(user, 1, 'deals', 'create')).toBe(true);
      expect(hasCrmManagePermission(user, 1, 'tasks', 'create')).toBe(true);
    });
  });

  it('respects partial grants, account switch and missing DTO fields', () => {
    const user = {
      accounts: [
        membership(1, {
          crm_capabilities: { deals: ['view', 'create'], tasks: ['view'] },
          crm_grant_scopes: {
            deals: { view: 'all', create: 'own' },
            tasks: { view: 'all' },
          },
        }),
        membership(2, {
          permissions: ['administrator'],
          crm_capabilities: { deals: ['view'], tasks: ['view'] },
          crm_grant_scopes: { deals: { view: 'all' }, tasks: { view: 'all' } },
        }),
      ],
    };
    expect(hasCrmManagePermission(user, 1, 'deals', 'create')).toBe(true);
    expect(hasCrmManagePermission(user, 1, 'deals')).toBe(false);
    expect(hasCrmManagePermission(user, 2, 'deals', 'create')).toBe(false);
    expect(hasCrmManagePermission(user, 3, 'deals')).toBe(false);
    expect(
      hasCrmManagePermission(
        { accounts: [membership(1, { crm_capabilities: undefined })] },
        1,
        'tasks'
      )
    ).toBe(false);
  });

  it('enforces action and record scopes for own/team/all grants', () => {
    const user = {
      id: 7,
      accounts: [
        membership(1, {
          crm_team_ids: [12],
          crm_grant_scopes: {
            deals: {
              view: 'all',
              create: 'own',
              assign: 'own',
              update_fields: 'team',
              transition: 'own',
              delete_archive: 'none',
            },
            tasks: { view: 'all', complete_cancel: 'own', transition: 'none' },
          },
        }),
      ],
    };
    const own = { id: 10, ownerId: 7, assigneeId: 7, teamId: 12 };
    const teammate = { id: 11, ownerId: 8, assigneeId: 8, teamId: 12 };
    const outsider = { id: 12, ownerId: 8, assigneeId: 8, teamId: 13 };
    expect(hasCrmManagePermission(user, 1, 'deals', 'update_fields', own)).toBe(
      true
    );
    expect(
      hasCrmManagePermission(user, 1, 'deals', 'update_fields', teammate)
    ).toBe(true);
    expect(
      hasCrmManagePermission(user, 1, 'deals', 'update_fields', outsider)
    ).toBe(false);
    expect(hasCrmManagePermission(user, 1, 'deals', 'update_fields')).toBe(
      false
    );
    expect(
      hasCrmManagePermission(user, 1, 'deals', 'transition', teammate)
    ).toBe(false);
    expect(
      hasCrmManagePermission(user, 1, 'tasks', 'complete_cancel', own)
    ).toBe(true);
    expect(
      hasCrmManagePermission(user, 1, 'tasks', 'complete_cancel', teammate)
    ).toBe(false);
    expect(
      hasCrmManagePermission(user, 1, 'deals', ['create', 'assign'], {
        ownerId: 7,
        teamId: 12,
      })
    ).toBe(true);
    expect(
      hasCrmManagePermission(user, 1, 'deals', ['create', 'assign'], {
        ownerId: 8,
      })
    ).toBe(false);
    expect(
      hasCrmManagePermission(user, 1, 'deals', ['create', 'assign'], {
        ownerId: 7,
        teamId: 13,
      })
    ).toBe(false);
  });

  it('fails closed for mutation when the enforced DTO omits scopes or a capability', () => {
    const user = {
      id: 7,
      accounts: [
        membership(1, {
          crm_grant_scopes: undefined,
        }),
      ],
    };
    expect(hasCrmViewPermission(user, 1, 'deals')).toBe(true);
    expect(hasCrmManagePermission(user, 1, 'deals', 'create')).toBe(false);
    expect(
      hasCrmManagePermission(user, 1, 'deals', 'transition', {
        id: 2,
        ownerId: 7,
      })
    ).toBe(false);
    user.accounts[0].crm_grant_scopes = { deals: { create: 'all' } };
    expect(hasCrmManagePermission(user, 1, 'deals', 'assign')).toBe(false);
  });

  it('allows server-authorized team and all creation targets without requiring actor ownership', () => {
    const user = {
      id: 7,
      accounts: [
        membership(1, {
          crm_team_ids: [12],
          crm_grant_scopes: {
            deals: { create: 'team', assign: 'team' },
            tasks: { create: 'team', assign: 'team' },
          },
        }),
      ],
    };
    expect(
      hasCrmManagePermission(user, 1, 'deals', ['create', 'assign'], {
        ownerId: 8,
        teamId: 12,
      })
    ).toBe(true);
    expect(
      hasCrmManagePermission(user, 1, 'tasks', ['create', 'assign'], {
        assigneeId: 8,
        teamId: 12,
      })
    ).toBe(true);
    expect(
      hasCrmManagePermission(user, 1, 'tasks', ['create', 'assign'], {
        assigneeId: 8,
        teamId: 13,
      })
    ).toBe(false);
    user.accounts[0].crm_grant_scopes.tasks.assign = 'all';
    expect(
      hasCrmManagePermission(user, 1, 'tasks', ['create', 'assign'], {
        assigneeId: 8,
        teamId: 13,
      })
    ).toBe(true);
  });

  it('preserves legacy/shadow role tokens and custom CRM grants', () => {
    ['legacy', 'shadow'].forEach(mode => {
      [['agent'], ['administrator'], ['crm_deal_manage']].forEach(
        permissions => {
          const user = {
            accounts: [
              membership(1, {
                access_control_mode: mode,
                permissions,
                crm_capabilities: undefined,
              }),
            ],
          };
          expect(hasCrmManagePermission(user, 1, 'deals')).toBe(true);
        }
      );
    });
    const user = {
      accounts: [membership(1, { access_control_mode: undefined })],
    };
    expect(hasCrmManagePermission(user, 1, 'deals')).toBe(false);
  });

  it('fails closed on a simulated sequence of old/new profile DTOs in the new helper', () => {
    // Old _user.json.jbuilder blob 45ec94d9 exposes permissions but no mode/scopes.
    const oldProfile = { id: 1, permissions: ['agent'] };
    const newObserverProfile = {
      ...membership(1, {
        permissions: ['agent'],
        crm_capabilities: { deals: ['view'], tasks: ['view'] },
        crm_grant_scopes: { deals: { view: 'all' }, tasks: { view: 'all' } },
      }),
    };
    [oldProfile, newObserverProfile, oldProfile, newObserverProfile].forEach(
      account => {
        const user = { accounts: [account] };
        expect(hasCrmManagePermission(user, 1, 'deals', 'create')).toBe(false);
        expect(hasCrmManagePermission(user, 1, 'tasks', 'create')).toBe(false);
        expect(hasCrmViewPermission(user, 1, 'deals')).toBe(true);
      }
    );
    // The old browser ignores new grants and may still show a button. API RBAC
    // must enforce the Observer role; the client token is not authorization.
    expect(
      hasPermissions(
        CRM_DEAL_MANAGE_PERMISSIONS,
        newObserverProfile.permissions
      )
    ).toBe(true);
  });
});

describe('hasPermissions', () => {
  it('returns true if permission is present', () => {
    expect(
      hasPermissions(['contact_manage'], ['team_manage', 'contact_manage'])
    ).toBe(true);
  });

  it('returns true if permission is not present', () => {
    expect(
      hasPermissions(['contact_manage'], ['team_manage', 'user_manage'])
    ).toBe(false);
    expect(hasPermissions()).toBe(false);
    expect(hasPermissions([])).toBe(false);
  });
});

describe('filterItemsByPermission', () => {
  const items = {
    item1: { name: 'Item 1', permissions: ['agent', 'administrator'] },
    item2: {
      name: 'Item 2',
      permissions: [
        'conversation_manage',
        'conversation_unassigned_manage',
        'conversation_participating_manage',
      ],
    },
    item3: { name: 'Item 3', permissions: ['contact_manage'] },
    item4: { name: 'Item 4', permissions: ['report_manage'] },
    item5: { name: 'Item 5', permissions: ['knowledge_base_manage'] },
    item6: {
      name: 'Item 6',
      permissions: [
        'agent',
        'administrator',
        'conversation_manage',
        'conversation_unassigned_manage',
        'conversation_participating_manage',
        'contact_manage',
        'report_manage',
        'knowledge_base_manage',
      ],
    },
    item7: { name: 'Item 7', permissions: [] },
  };

  const getPermissions = item => item.permissions;

  it('filters items based on user permissions', () => {
    const userPermissions = ['agent', 'contact_manage', 'report_manage'];
    const result = filterItemsByPermission(
      items,
      userPermissions,
      getPermissions
    );

    expect(result).toHaveLength(5);
    expect(result).toContainEqual(
      expect.objectContaining({ key: 'item1', name: 'Item 1' })
    );
    expect(result).toContainEqual(
      expect.objectContaining({ key: 'item3', name: 'Item 3' })
    );
    expect(result).toContainEqual(
      expect.objectContaining({ key: 'item4', name: 'Item 4' })
    );
    expect(result).toContainEqual(
      expect.objectContaining({ key: 'item6', name: 'Item 6' })
    );
  });

  it('includes items with empty permissions', () => {
    const userPermissions = [];
    const result = filterItemsByPermission(
      items,
      userPermissions,
      getPermissions
    );

    expect(result).toHaveLength(1);
    expect(result).toContainEqual(
      expect.objectContaining({ key: 'item7', name: 'Item 7' })
    );
  });

  it('uses custom transform function when provided', () => {
    const userPermissions = ['agent', 'contact_manage'];
    const customTransform = (key, item) => ({ id: key, title: item.name });
    const result = filterItemsByPermission(
      items,
      userPermissions,
      getPermissions,
      customTransform
    );

    expect(result).toHaveLength(4);
    expect(result).toContainEqual({ id: 'item1', title: 'Item 1' });
    expect(result).toContainEqual({ id: 'item3', title: 'Item 3' });
    expect(result).toContainEqual({ id: 'item6', title: 'Item 6' });
  });

  it('handles empty items object', () => {
    const result = filterItemsByPermission({}, ['agent'], getPermissions);

    expect(result).toHaveLength(0);
  });

  it('handles custom getPermissions function', () => {
    const customItems = {
      item1: { name: 'Item 1', requiredPerms: ['agent', 'administrator'] },
      item2: { name: 'Item 2', requiredPerms: ['contact_manage'] },
    };
    const customGetPermissions = item => item.requiredPerms;
    const result = filterItemsByPermission(
      customItems,
      ['agent'],
      customGetPermissions
    );

    expect(result).toHaveLength(1);
    expect(result).toContainEqual(
      expect.objectContaining({ key: 'item1', name: 'Item 1' })
    );
  });
});

describe('runtime access permission sets', () => {
  it('includes plain roles and custom-role permissions for conversation access', () => {
    expect(CONVERSATION_ACCESS_PERMISSIONS).toEqual([
      ...ROLES,
      ...CONVERSATION_PERMISSIONS,
    ]);
  });

  it('includes plain roles and custom-role permissions for contact access', () => {
    expect(CONTACT_ACCESS_PERMISSIONS).toEqual([...ROLES, CONTACT_PERMISSIONS]);
  });

  it('includes plain roles and custom-role permissions for CRM deals', () => {
    expect(CRM_DEAL_VIEW_PERMISSIONS).toEqual([
      ...ROLES,
      CRM_DEAL_VIEW_PERMISSION,
      CRM_DEAL_MANAGE_PERMISSION,
    ]);
    expect(CRM_DEAL_MANAGE_PERMISSIONS).toEqual([
      ...ROLES,
      CRM_DEAL_MANAGE_PERMISSION,
    ]);
  });

  it('includes plain roles and custom-role permissions for CRM tasks', () => {
    expect(CRM_TASK_VIEW_PERMISSIONS).toEqual([
      ...ROLES,
      CRM_TASK_VIEW_PERMISSION,
      CRM_TASK_MANAGE_PERMISSION,
    ]);
    expect(CRM_TASK_MANAGE_PERMISSIONS).toEqual([
      ...ROLES,
      CRM_TASK_MANAGE_PERMISSION,
    ]);
  });

  it('keeps scheduling runtime access feature-flag based for every account role type', () => {
    expect(SCHEDULING_ACCESS_PERMISSIONS).toEqual([
      'administrator',
      'agent',
      'custom_role',
    ]);
  });

  it('lets plain agents use main CRM and scheduling surfaces without CRM settings permissions', () => {
    const agentPermissions = ['agent'];

    expect(hasPermissions(CRM_DEAL_VIEW_PERMISSIONS, agentPermissions)).toBe(
      true
    );
    expect(hasPermissions(CRM_TASK_VIEW_PERMISSIONS, agentPermissions)).toBe(
      true
    );
    expect(
      hasPermissions(SCHEDULING_ACCESS_PERMISSIONS, agentPermissions)
    ).toBe(true);
    expect(
      hasPermissions(
        [CRM_SETTINGS_VIEW_PERMISSION, CRM_SETTINGS_MANAGE_PERMISSION],
        agentPermissions
      )
    ).toBe(false);
  });
});
