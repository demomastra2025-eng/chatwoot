const systemRoleLabel = (systemKey, t) => {
  const labels = {
    administrator: t('CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.ADMINISTRATOR'),
    employee: t('CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.EMPLOYEE'),
    department_lead: t(
      'CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.DEPARTMENT_LEAD'
    ),
    commercial_director: t(
      'CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.COMMERCIAL_DIRECTOR'
    ),
    observer: t('CUSTOM_ROLE.ACCESS_MATRIX.SYSTEM_ROLES.OBSERVER'),
  };

  return labels[systemKey];
};

const canonicalOption = (role, t) => ({
  id: `access:${role.id}`,
  accessRoleId: role.id,
  label: role.system_key ? systemRoleLabel(role.system_key, t) : role.name,
  mode: 'canonical',
});

const legacyOptions = (customRoles, t) => [
  {
    id: 'legacy:administrator',
    role: 'administrator',
    label: t('AGENT_MGMT.AGENT_TYPES.ADMINISTRATOR'),
    mode: 'legacy',
  },
  {
    id: 'legacy:agent',
    role: 'agent',
    label: t('AGENT_MGMT.AGENT_TYPES.AGENT'),
    mode: 'legacy',
  },
  ...customRoles.map(role => ({
    id: `legacy-custom:${role.id}`,
    customRoleId: role.id,
    label: role.name,
    mode: 'legacy',
  })),
];

export const buildAgentRoleOptions = ({ catalog, customRoles, t }) => {
  if (catalog.assignmentsEnabled) {
    return catalog.records.map(role => canonicalOption(role, t));
  }

  return legacyOptions(customRoles, t);
};

export const initialAgentRoleOptionId = ({
  catalog,
  accessRoleId,
  customRoleId,
  role,
}) => {
  if (catalog.assignmentsEnabled) {
    return accessRoleId ? `access:${accessRoleId}` : null;
  }
  if (customRoleId) return `legacy-custom:${customRoleId}`;

  return role ? `legacy:${role}` : null;
};

export const buildAgentRoleAssignment = ({ option, previousAccessRoleId }) => {
  if (option.mode === 'canonical') {
    return {
      access_role_id: option.accessRoleId,
      ...(previousAccessRoleId === undefined
        ? {}
        : { previous_access_role_id: previousAccessRoleId }),
    };
  }
  if (option.customRoleId) {
    return { custom_role_id: option.customRoleId };
  }

  return { role: option.role, custom_role_id: null };
};

export const getAccessRoleDisplayName = ({ catalog, accessRoleId, t }) => {
  const role = catalog.records.find(item => item.id === accessRoleId);
  if (!role) return '';

  return role.system_key ? systemRoleLabel(role.system_key, t) : role.name;
};

export const isAgentAssignmentCatalogReady = ({ catalog, isFetching }) => {
  return !isFetching && (catalog.loaded || Boolean(catalog.error));
};
