import {
  CRM_DEAL_MANAGE_PERMISSIONS,
  CRM_DEAL_VIEW_PERMISSIONS,
  CRM_TASK_MANAGE_PERMISSIONS,
  CRM_TASK_VIEW_PERMISSIONS,
} from 'dashboard/constants/permissions';

export const hasPermissions = (
  requiredPermissions = [],
  availablePermissions = []
) => {
  return requiredPermissions.some(permission =>
    availablePermissions.includes(permission)
  );
};

export const getCurrentAccount = ({ accounts } = {}, accountId = null) => {
  return accounts.find(account => Number(account.id) === Number(accountId));
};

export const getUserPermissions = (user, accountId) => {
  const currentAccount = getCurrentAccount(user, accountId) || {};
  return currentAccount.permissions || [];
};

// Legacy role tokens do not imply AccessRole grants in enforced accounts.
const CRM_MANAGE_CAPABILITIES = {
  deals: ['create', 'update_fields', 'assign', 'transition', 'delete_archive'],
  tasks: [
    'create',
    'update_fields',
    'assign',
    'transition',
    'complete_cancel',
    'delete_archive',
  ],
};

const hasCrmPermission = (
  user,
  accountId,
  resource,
  capabilities,
  legacyPermissions,
  record = null
) => {
  const account = user?.accounts?.find(
    item => Number(item.id) === Number(accountId)
  );
  if (!account || !CRM_MANAGE_CAPABILITIES[resource]) return false;

  if (account.access_control_mode === 'enforced') {
    const scopes = account.crm_grant_scopes?.[resource];
    if (!scopes || typeof scopes !== 'object' || Array.isArray(scopes)) {
      // Older web nodes publish view grants without scopes. Mutations fail closed.
      return capabilities.length === 1 && capabilities[0] === 'view'
        ? account.crm_capabilities?.[resource]?.includes('view') === true
        : false;
    }
    return capabilities.every(capability => {
      const scope = scopes[capability];
      if (!['own', 'team', 'all'].includes(scope)) return false;
      if (capability === 'view') return true;
      if (capabilities.includes('create') && record && !record.id) {
        if (capability === 'create') return true;
        if (capability !== 'assign') return false;
        const targetId = Number(
          resource === 'deals' ? record.ownerId : record.assigneeId
        );
        const teamId = Number(record.teamId);
        const teamIds = account.crm_team_ids;
        if (scope === 'own') {
          return (
            targetId === Number(user.id) &&
            (!teamId || (Array.isArray(teamIds) && teamIds.includes(teamId)))
          );
        }
        if (scope === 'team') {
          return (
            (!teamId && targetId === Number(user.id)) ||
            (teamId && Array.isArray(teamIds) && teamIds.includes(teamId))
          );
        }
        // The server validates that the selected target belongs to the team.
        return true;
      }
      if (!record) {
        return (
          ['create', 'assign'].includes(capability) &&
          capabilities.includes('create')
        );
      }
      if (!Number.isFinite(Number(record.id)) || Number(record.id) <= 0) {
        return false;
      }
      if (scope === 'all') return true;
      const recordUserId = Number(
        resource === 'deals' ? record.ownerId : record.assigneeId
      );
      if (recordUserId > 0 && recordUserId === Number(user.id)) return true;
      return (
        scope === 'team' &&
        Number(record.teamId) > 0 &&
        Array.isArray(account.crm_team_ids) &&
        account.crm_team_ids.some(id => Number(id) === Number(record.teamId))
      );
    });
  }

  if (['legacy', 'shadow'].includes(account.access_control_mode)) {
    return hasPermissions(legacyPermissions, account.permissions || []);
  }

  if (
    !account.access_control_mode &&
    capabilities.length === 1 &&
    capabilities[0] === 'view'
  ) {
    return hasPermissions(legacyPermissions, account.permissions || []);
  }

  // Older or incomplete profile payloads must not enable mutation controls.
  return false;
};

export const hasCrmManagePermission = (
  user,
  accountId,
  resource,
  capabilities = CRM_MANAGE_CAPABILITIES[resource],
  record = null
) =>
  hasCrmPermission(
    user,
    accountId,
    resource,
    Array.isArray(capabilities) ? capabilities : [capabilities],
    resource === 'deals'
      ? CRM_DEAL_MANAGE_PERMISSIONS
      : CRM_TASK_MANAGE_PERMISSIONS,
    record
  );

export const hasCrmViewPermission = (user, accountId, resource) =>
  hasCrmPermission(
    user,
    accountId,
    resource,
    ['view'],
    resource === 'deals' ? CRM_DEAL_VIEW_PERMISSIONS : CRM_TASK_VIEW_PERMISSIONS
  );

export const hasRouteViewPermission = (
  user,
  accountId,
  routePermissions = [],
  crmResources = []
) =>
  crmResources.length
    ? crmResources.some(resource =>
        hasCrmViewPermission(user, accountId, resource)
      )
    : hasPermissions(routePermissions, getUserPermissions(user, accountId));

export const getUserRole = (user, accountId) => {
  const currentAccount = getCurrentAccount(user, accountId) || {};
  if (currentAccount.custom_role_id) {
    return 'custom_role';
  }

  return currentAccount.role || 'agent';
};

/**
 * Filters and transforms items based on user permissions.
 *
 * @param {Object} items - An object containing items to be filtered.
 * @param {Array} userPermissions - Array of permissions the user has.
 * @param {Function} getPermissions - Function to extract required permissions from an item.
 * @param {Function} [transformItem] - Optional function to transform each item after filtering.
 * @returns {Array} Filtered and transformed items.
 */
export const filterItemsByPermission = (
  items,
  userPermissions,
  getPermissions,
  transformItem = (key, item) => ({ key, ...item })
) => {
  // Helper function to check if an item has the required permissions
  const hasRequiredPermissions = item => {
    const requiredPermissions = getPermissions(item);
    return (
      requiredPermissions.length === 0 ||
      hasPermissions(requiredPermissions, userPermissions)
    );
  };

  return Object.entries(items)
    .filter(([, item]) => hasRequiredPermissions(item)) // Keep only items with required permissions
    .map(([key, item]) => transformItem(key, item)); // Transform each remaining item
};
